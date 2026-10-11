/// Message entry point: parsing, the three document notifications, rejection replies.
/// Knows no other LSP method.
const std = @import("std");
const Document = @import("text.zig").Document;
const json_validation = @import("lua.zig").convert;
const lua_calls = @import("lua.zig").core.lua_calls;
const Runtime = @import("Runtime.zig");

const Allocator = std.mem.Allocator;

pub const parse_error = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}";

const Notification = enum { didOpen, didChange, didClose };

/// The caller frees `bytes`.
pub fn onMessage(runtime: *Runtime, bytes: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(runtime.gpa);
    defer arena.deinit();

    if (!json_validation.isNestingWithinLimit(bytes)) {
        runtime.log(2, "dropped a message nested deeper than 128 levels");
        runtime.client_writer.push(runtime.io, parse_error);
        return;
    }

    const message = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), bytes, .{}) catch {
        runtime.client_writer.push(runtime.io, parse_error);
        return;
    };

    const kind = classify(message);
    const encoding_known = runtime.documents.encoding != null;
    if (encoding_known and kind == .didOpen) {
        applyOpen(runtime, arena.allocator(), message);
    }
    if (encoding_known and kind == .didChange) {
        applyChange(runtime, arena.allocator(), message);
    }

    lua_calls.callOnMessage(runtime, message);

    if (encoding_known and kind == .didClose) {
        applyClose(runtime, arena.allocator(), message);
    }
}

/// A request that never reaches Lua still gets an answer (a missing reply hangs the client).
pub fn rejectUnconvertible(runtime: *Runtime, message: std.json.Value, text: []const u8) void {
    if (message != .object) {
        return;
    }

    const id = message.object.get("id") orelse return;
    const method = message.object.get("method") orelse return;
    if (method != .string) {
        return;
    }

    const reply = .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = -32603, .message = text } };
    const bytes = std.json.Stringify.valueAlloc(runtime.gpa, reply, .{}) catch return;

    runtime.client_writer.pushOwned(runtime.io, bytes);
}

/// Which of the three document notifications `message` is, if any.
fn classify(message: std.json.Value) ?Notification {
    if (message != .object or message.object.contains("id")) {
        return null;
    }

    const method = message.object.get("method") orelse return null;
    if (method != .string) {
        return null;
    }

    const name = std.mem.cutPrefix(u8, method.string, "textDocument/") orelse return null;

    return std.meta.stringToEnum(Notification, name);
}

test "classify tells notifications from requests" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const open = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"method\":\"textDocument/didOpen\"}", .{});
    try std.testing.expectEqual(Notification.didOpen, classify(open).?);

    const request = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"id\":1,\"method\":\"textDocument/didOpen\"}", .{});
    try std.testing.expect(classify(request) == null);
}

const Position = struct { line: i64, character: i64 };

/// One entry of `contentChanges`: a ranged edit, or a whole-text replacement when `range` is null.
const Change = struct {
    range: ?struct { start: Position, end: Position } = null,
    text: []const u8,
};

const OpenParams = struct {
    textDocument: struct { uri: []const u8, languageId: []const u8, version: i64, text: []const u8 },
};

const ChangeParams = struct {
    textDocument: struct { uri: []const u8, version: i64 },
    contentChanges: []const Change,
};

const CloseParams = struct {
    textDocument: struct { uri: []const u8 },
};

/// The notification's `params` as `T`, or a logged warning and null.
fn parseParams(comptime T: type, runtime: *Runtime, arena: Allocator, message: std.json.Value, name: []const u8) ?T {
    if (message.object.get("params")) |params| {
        if (std.json.parseFromValueLeaky(T, arena, params, .{ .ignore_unknown_fields = true })) |parsed| {
            return parsed;
        } else |_| {}
    }

    warn(runtime, "{s}: malformed parameters", .{name});

    return null;
}

pub fn applyOpen(runtime: *Runtime, arena: Allocator, message: std.json.Value) void {
    const params = parseParams(OpenParams, runtime, arena, message, "didOpen") orelse return;
    const item = params.textDocument;

    // A reopen without didClose must not reuse the old tree.
    runtime.trees.dropDocument(item.uri);
    runtime.documents.open(item.uri, item.languageId, item.version, item.text) catch {
        warn(runtime, "didOpen: out of memory", .{});
    };
}

pub fn applyChange(runtime: *Runtime, arena: Allocator, message: std.json.Value) void {
    const params = parseParams(ChangeParams, runtime, arena, message, "didChange") orelse return;

    // Validate everything first so a malformed entry leaves the document untouched.
    for (params.contentChanges) |change| {
        const range = change.range orelse continue;
        if (@min(range.start.line, range.start.character, range.end.line, range.end.character) < 0) {
            return warn(runtime, "didChange: malformed parameters", .{});
        }
    }

    const uri = params.textDocument.uri;
    const document = runtime.documents.find(uri) orelse return warn(runtime, "didChange: {s} is not open", .{uri});
    const encoding = runtime.documents.encoding.?;
    for (params.contentChanges) |change| {
        applyOne(runtime, document, encoding, change) catch {
            return warn(runtime, "didChange: out of memory", .{});
        };
    }

    document.version = params.textDocument.version;
}

pub fn applyClose(runtime: *Runtime, arena: Allocator, message: std.json.Value) void {
    const params = parseParams(CloseParams, runtime, arena, message, "didClose") orelse return;
    const uri = params.textDocument.uri;

    runtime.trees.dropDocument(uri);
    if (!runtime.documents.close(uri)) {
        warn(runtime, "didClose: {s} is not open", .{uri});
    }
}

fn applyOne(runtime: *Runtime, document: *Document, encoding: Document.Encoding, change: Change) Allocator.Error!void {
    const range = change.range orelse {
        runtime.trees.invalidateBases(document.uri);
        return document.setText(change.text);
    };

    var start = document.offsetFromPosition(encoding, clampPosition(range.start));
    var end = document.offsetFromPosition(encoding, clampPosition(range.end));
    if (end < start) {
        std.mem.swap(usize, &start, &end);
    }

    runtime.trees.recordEdit(document.uri, try document.replace(start, end, change.text));
}

fn clampPosition(position: Position) Document.Position {
    return .{
        .line = @intCast(@min(position.line, std.math.maxInt(u32))),
        .character = @intCast(@min(position.character, std.math.maxInt(u32))),
    };
}

fn warn(runtime: *Runtime, comptime format: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    runtime.log(2, std.fmt.bufPrint(&buffer, format, args) catch &buffer);
}

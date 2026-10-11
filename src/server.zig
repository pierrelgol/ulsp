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

//! Plain Lua-callable functions: client, json, uri and operations, plus pushing operation results.

const convert = @import("convert.zig");
const std = @import("std");
const zlua = @import("zlua");
const Document = @import("../text.zig").Document;
const Runtime = @import("../Runtime.zig");
const uri = @import("../text.zig").uri;
const operations = @import("../ops.zig");
const RunSpec = @import("../ops.zig").RunSpec;
const DirectoryEntry = @import("../ops.zig").DirectoryEntry;
const FileStat = @import("../ops.zig").FileStat;
const ProcessResult = @import("../ops.zig").ProcessResult;

const raise = convert.raise;
const Lua = zlua.Lua;
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;

/// The JSON text of the Lua value at index 1, owned by the caller.
fn encodeArgument(lua: *Lua, runtime: *Runtime) []u8 {
    lua.checkAny(1);

    // Raise only after the arena is gone: a Lua error longjmps over `defer`.
    var arena: std.heap.ArenaAllocator = .init(runtime.gpa);
    const encoded: convert.Error![]u8 = blk: {
        defer arena.deinit();

        const value = convert.toJson(lua, runtime.tags, arena.allocator(), 1) catch |err| break :blk err;

        break :blk std.json.Stringify.valueAlloc(runtime.gpa, value, .{}) catch error.OutOfMemory;
    };

    return encoded catch |err| raise.text(lua, convert.errorText(err));
}

/// `core` functions that talk to the client or the process: send, log, exit, set_encoding.
pub const client_calls = struct {
    pub fn send(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);

        runtime.client_writer.pushOwned(runtime.io, encodeArgument(lua, runtime));

        return 0;
    }

    pub fn log(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const level = lua.checkInteger(1);
        const text = lua.checkString(2);

        runtime.log(@intCast(std.math.clamp(level, 1, 4)), text);

        return 0;
    }

    pub fn exit(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const code = lua.checkInteger(1);

        runtime.exit_code = @intCast(std.math.clamp(code, 0, 255));

        return 0;
    }

    pub fn setEncoding(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const name = lua.checkString(1);

        const encoding = std.meta.stringToEnum(Document.Encoding, name) orelse .@"utf-32";
        if (encoding == .@"utf-32") {
            lua.argError(1, "expected \"utf-8\" or \"utf-16\"");
        }
        if (runtime.documents.encoding != null) {
            raise.text(lua, "ulsp: encoding already set");
        }

        runtime.documents.encoding = encoding;

        return 0;
    }
};

/// `core.json_encode`, `core.json_decode`, `core.array` and `core.object`.
pub const json_calls = struct {
    pub fn encode(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const encoded = encodeArgument(lua, runtime);
        defer runtime.gpa.free(encoded);

        _ = lua.pushString(encoded);

        return 1;
    }

    pub fn decode(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const text = lua.checkString(1);
        if (!convert.isNestingWithinLimit(text)) {
            raise.text(lua, "ulsp.json.decode: nested too deeply");
        }

        // Raise only after the arena is gone: a Lua error longjmps over `defer`.
        var arena: std.heap.ArenaAllocator = .init(runtime.gpa);
        const failure_message: ?[]const u8 = blk: {
            defer arena.deinit();

            const value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{}) catch {
                break :blk "ulsp.json.decode: invalid JSON";
            };
            convert.push(lua, runtime.tags, value) catch |err| break :blk convert.errorText(err);

            break :blk null;
        };
        if (failure_message) |message| {
            raise.text(lua, message);
        }

        return 1;
    }

    /// `core.array(t)` / `core.object(t)`: tags `t` (or a new table) as a JSON array or object.
    pub fn markShape(comptime is_array: bool) fn (*Lua) i32 {
        return struct {
            fn mark(lua: *Lua) i32 {
                const runtime = Runtime.of(lua);

                if (lua.isNoneOrNil(1)) {
                    lua.createTable(0, 0);
                } else {
                    lua.checkType(1, .table);
                    lua.pushValue(1);
                }
                runtime.tags.push(lua, is_array);
                lua.setMetatable(-2);

                return 1;
            }
        }.mark;
    }
};

/// `core.uri_to_path` and `core.uri_from_path`.
pub const uri_calls = struct {
    pub fn toPath(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const uri_text = lua.checkString(1);

        const maybe_path = uri.toPath(runtime.gpa, uri_text) catch raise.text(lua, "out of memory");
        const path = maybe_path orelse {
            lua.pushNil();
            return 1;
        };
        defer runtime.gpa.free(path);

        _ = lua.pushString(path);

        return 1;
    }

    pub fn fromPath(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const path = lua.checkString(1);

        const uri_text = uri.fromPath(runtime.gpa, path) catch raise.text(lua, "out of memory");
        defer runtime.gpa.free(uri_text);

        _ = lua.pushString(uri_text);

        return 1;
    }
};

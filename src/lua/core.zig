const convert = @import("convert.zig");
const api = @import("api.zig");
pub const document_calls = @import("document.zig").document_calls;
const ts_calls = @import("ts.zig").ts_calls;
const client_calls = api.client_calls;
const json_calls = api.json_calls;
const operation_calls = api.operation_calls;
const uri_calls = api.uri_calls;
const operation_results = api.operation_results;
const zlua = @import("zlua");
const std = @import("std");
const Operation = @import("../ops.zig").Operation;
const Runtime = @import("../Runtime.zig");
const Lua = zlua.Lua;
const wrap = zlua.wrap;

pub fn push(lua: *Lua) void {
    lua.createTable(0, 32);

    inline for (.{
        .{ "send", client_calls.send },
        .{ "log", client_calls.log },
        .{ "exit", client_calls.exit },
        .{ "set_encoding", client_calls.setEncoding },
        .{ "op_sleep", operation_calls.startSleep },
        .{ "op_run", operation_calls.startRun },
        .{ "op_read", operation_calls.startPathOperation("read") },
        .{ "op_write", operation_calls.startWrite },
        .{ "op_stat", operation_calls.startPathOperation("stat") },
        .{ "op_list", operation_calls.startPathOperation("list") },
        .{ "op_cancel", operation_calls.cancel },
        .{ "json_encode", json_calls.encode },
        .{ "json_decode", json_calls.decode },
        .{ "array", json_calls.markShape(true) },
        .{ "object", json_calls.markShape(false) },
        .{ "doc_get", document_calls.get },
        .{ "doc_list", document_calls.list },
        .{ "uri_to_path", uri_calls.toPath },
        .{ "uri_from_path", uri_calls.fromPath },
    }) |entry| {
        lua.pushFunction(wrap(entry[1]));
        lua.setField(-2, entry[0]);
    }

    ts_calls.register(lua);
    convert.pushNull(lua);
    lua.setField(-2, "null");
}

pub const lua_calls = struct {
    const Call = union(enum) {
        message: std.json.Value,
        completion: *Operation,
    };

    pub fn callOnMessage(runtime: *Runtime, value: std.json.Value) void {
        protectedEntry(runtime, &.{ .message = value });
    }

    pub fn callOnCompletion(runtime: *Runtime, operation: *Operation) void {
        protectedEntry(runtime, &.{ .completion = operation });
    }

    pub fn logLuaError(runtime: *Runtime, what: []const u8) void {
        const lua = runtime.lua;
        const message = if (lua.getTop() > 0 and lua.typeOf(-1) == .string) lua.toString(-1) catch "" else "";

        var buffer: [4096]u8 = undefined;
        runtime.log(1, std.fmt.bufPrint(&buffer, "{s}: {s}", .{ what, message }) catch what);
    }

    fn protectedEntry(runtime: *Runtime, call: *const Call) void {
        const lua = runtime.lua;
        const base = lua.getTop();

        lua.pushFunction(zlua.wrap(addTraceback));
        lua.pushFunction(zlua.wrap(enter));
        lua.pushLightUserdata(call);
        lua.protectedCall(.{ .args = 1, .results = 0, .msg_handler = base + 1 }) catch {
            logLuaError(runtime, "error in embedded Lua");
        };

        lua.setTop(base);
    }

    fn addTraceback(lua: *Lua) i32 {
        const message: [:0]const u8 = if (lua.typeOf(1) == .string)
            (lua.toString(1) catch "")
        else
            "(error object is not a string)";
        lua.traceback(lua, message, 1);

        return 1;
    }

    fn enter(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const call: *const Call = @ptrCast(@alignCast(lua.toPointer(1).?));

        switch (call.*) {
            .message => |value| enterOnMessage(lua, runtime, value),
            .completion => |operation| enterOnCompletion(lua, runtime, operation),
        }

        return 0;
    }

    fn enterOnMessage(lua: *Lua, runtime: *Runtime, value: std.json.Value) void {
        _ = lua.getIndexRaw(zlua.registry_index, runtime.on_message_ref);

        convert.push(lua, runtime.tags, value) catch |err| {
            runtime.hooks.reject(runtime, value, convert.errorText(err));
            lua.raiseErrorStr("%s", .{convert.errorText(err).ptr});
        };

        lua.call(.{ .args = 1, .results = 0 });
    }

    fn enterOnCompletion(lua: *Lua, runtime: *Runtime, operation: *Operation) void {
        _ = lua.getIndexRaw(zlua.registry_index, runtime.on_completion_ref);
        lua.pushInteger(@intCast(operation.id));

        switch (operation.result) {
            .failed => |text| {
                lua.pushBoolean(false);
                _ = lua.pushString(text);
            },
            else => {
                lua.pushBoolean(true);
                operation_results.push(lua, runtime, operation.result);
            },
        }

        lua.call(.{ .args = 3, .results = 0 });
    }
};

pub const embedded_lua = struct {
    pub fn load(runtime: *Runtime) error{ OutOfMemory, EmbeddedLuaFailed }!void {
        const lua = runtime.lua;
        defer lua.setTop(0);

        var arena: std.heap.ArenaAllocator = .init(runtime.gpa);
        defer arena.deinit();
        const directory = try luaDirectory(runtime, arena.allocator());

        try loadFile(runtime, arena.allocator(), directory, "async.lua");
        lua.pushValue(1);
        lua.protectedCall(.{ .args = 1, .results = 1 }) catch return error.EmbeddedLuaFailed;

        try loadFile(runtime, arena.allocator(), directory, "prelude.lua");
        lua.pushValue(1);
        lua.pushValue(2);
        lua.protectedCall(.{ .args = 2, .results = 2 }) catch return error.EmbeddedLuaFailed;

        if (lua.typeOf(-1) != .function or lua.typeOf(-2) != .function) {
            return error.EmbeddedLuaFailed;
        }
        runtime.on_completion_ref = lua.ref(zlua.registry_index);
        runtime.on_message_ref = lua.ref(zlua.registry_index);
    }

    fn luaDirectory(runtime: *Runtime, arena: std.mem.Allocator) error{ OutOfMemory, EmbeddedLuaFailed }![]const u8 {
        if (runtime.environ.get("ULSP_LUA")) |directory| {
            return directory;
        }

        const binary = std.process.executableDirPathAlloc(runtime.io, arena) catch return error.EmbeddedLuaFailed;

        return std.fs.path.join(arena, &.{ binary, "..", "share", "ulsp", "lua" });
    }

    fn loadFile(runtime: *Runtime, arena: std.mem.Allocator, directory: []const u8, comptime name: [:0]const u8) error{ OutOfMemory, EmbeddedLuaFailed }!void {
        const path = try std.fs.path.join(arena, &.{ directory, name });
        const source = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, arena, .limited(1 << 20)) catch return error.EmbeddedLuaFailed;

        runtime.lua.loadBuffer(source, "=" ++ name, .text) catch return error.EmbeddedLuaFailed;
    }
};

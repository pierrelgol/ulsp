//! The `ulsp` module table, calling into Lua (handlers, completions) and loading the embedded Lua sources.

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

/// Pushes a fresh `core` table. `runtime.document_metatable_ref` must already be set.
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

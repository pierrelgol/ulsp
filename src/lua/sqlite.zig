const convert = @import("convert.zig");
const registerMetatable = @import("ts.zig").ts_calls.registerMetatable;
const std = @import("std");
const zlua = @import("zlua");
const c = @import("sqlite3");
const Runtime = @import("../Runtime.zig");

const Lua = zlua.Lua;
const raise = convert.raise;
const wrap = zlua.wrap;

pub const DatabaseBox = struct {
    pub const metatable_name = "ulsp.sqlite.db";

    maybe_handle: ?*c.sqlite3,

    fn argument(lua: *Lua) *c.sqlite3 {
        const box = lua.checkUserdata(DatabaseBox, 1, metatable_name);

        return box.maybe_handle orelse raise.text(lua, "ulsp.sqlite: database is closed");
    }

    fn close(lua: *Lua) i32 {
        const box = lua.toUserdata(DatabaseBox, 1) catch return 0;
        const handle = box.maybe_handle orelse return 0;

        _ = c.sqlite3_close_v2(handle);
        box.maybe_handle = null;

        return 0;
    }
};

pub const sqlite_calls = struct {
    pub fn register(lua: *Lua) void {
        lua.pushFunction(wrap(open));
        lua.setField(-2, "sqlite_open");

        registerMetatable(lua, DatabaseBox.metatable_name, .{
            .{ "exec", exec },
            .{ "query", query },
            .{ "close", DatabaseBox.close },
        }, DatabaseBox.close, null);
    }

    fn open(lua: *Lua) i32 {
        const path = lua.checkString(1);

        var maybe_handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
        if (c.sqlite3_open_v2(path.ptr, &maybe_handle, flags, null) != c.SQLITE_OK) {
            // sqlite3_open_v2 hands back a handle carrying the error even on failure.
            var buffer: [512]u8 = undefined;
            const message = copyMessage(&buffer, c.sqlite3_errmsg(maybe_handle));
            _ = c.sqlite3_close_v2(maybe_handle);
            raise.formatted(lua, "ulsp.sqlite.open: {s}", .{message});
        }

        const box = lua.newUserdata(DatabaseBox, 0);
        box.* = .{ .maybe_handle = maybe_handle };
        lua.setMetatableRegistry(DatabaseBox.metatable_name);

        return 1;
    }

    fn exec(lua: *Lua) i32 {
        const handle = DatabaseBox.argument(lua);
        const sql = lua.checkString(2);

        var maybe_error: [*c]u8 = null;
        if (c.sqlite3_exec(handle, sql.ptr, null, null, &maybe_error) != c.SQLITE_OK) {
            var buffer: [512]u8 = undefined;
            const message = copyMessage(&buffer, maybe_error);
            c.sqlite3_free(maybe_error);
            raise.formatted(lua, "ulsp.sqlite.exec: {s}", .{message});
        }

        return 0;
    }

    fn query(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const handle = DatabaseBox.argument(lua);
        const sql = lua.checkString(2);
        lua.checkStack(8) catch raise.text(lua, "out of memory");

        var maybe_statement: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(handle, sql.ptr, @intCast(sql.len), &maybe_statement, null) != c.SQLITE_OK) {
            raiseDatabase(lua, handle, null);
        }
        const statement = maybe_statement orelse raise.text(lua, "ulsp.sqlite.query: empty statement");

        // shortcut: a Lua out-of-memory error while pushing rows leaks the statement; fine until it shows up.
        bindArguments(lua, handle, statement);

        lua.createTable(0, 0);
        var row_count: i32 = 0;
        while (true) {
            const step = c.sqlite3_step(statement);
            if (step == c.SQLITE_DONE) {
                break;
            }
            if (step != c.SQLITE_ROW) {
                raiseDatabase(lua, handle, statement);
            }

            row_count += 1;
            pushRow(lua, statement);
            lua.setIndex(-2, row_count);
        }
        _ = c.sqlite3_finalize(statement);

        runtime.tags.push(lua, true);
        lua.setMetatable(-2);

        return 1;
    }

    fn bindArguments(lua: *Lua, handle: *c.sqlite3, statement: *c.sqlite3_stmt) void {
        const first_argument = 3;
        var index: i32 = first_argument;
        while (index <= lua.getTop()) : (index += 1) {
            const position = index - first_argument + 1;
            const result = switch (lua.typeOf(index)) {
                .nil => c.sqlite3_bind_null(statement, position),
                .boolean => c.sqlite3_bind_int(statement, position, @intFromBool(lua.toBoolean(index))),
                .number => bindNumber(lua, statement, position, index),
                .string => bindText(lua, statement, position, index),
                else => {
                    _ = c.sqlite3_finalize(statement);
                    lua.argError(index, "expected nil, boolean, number or string");
                },
            };
            if (result != c.SQLITE_OK) {
                raiseDatabase(lua, handle, statement);
            }
        }
    }

    fn bindNumber(lua: *Lua, statement: *c.sqlite3_stmt, position: i32, index: i32) c_int {
        if (lua.isInteger(index)) {
            return c.sqlite3_bind_int64(statement, position, lua.toInteger(index) catch unreachable);
        }

        return c.sqlite3_bind_double(statement, position, lua.toNumber(index) catch unreachable);
    }

    fn bindText(lua: *Lua, statement: *c.sqlite3_stmt, position: i32, index: i32) c_int {
        const text = lua.toString(index) catch unreachable;

        // SQLITE_STATIC: the argument stays on the Lua stack until the statement is finalized.
        return c.sqlite3_bind_text(statement, position, text.ptr, @intCast(text.len), c.SQLITE_STATIC);
    }

    fn pushRow(lua: *Lua, statement: *c.sqlite3_stmt) void {
        const column_count = c.sqlite3_column_count(statement);
        lua.createTable(0, column_count);

        var column: i32 = 0;
        while (column < column_count) : (column += 1) {
            switch (c.sqlite3_column_type(statement, column)) {
                c.SQLITE_NULL => continue,
                c.SQLITE_INTEGER => lua.pushInteger(c.sqlite3_column_int64(statement, column)),
                c.SQLITE_FLOAT => lua.pushNumber(c.sqlite3_column_double(statement, column)),
                else => _ = lua.pushString(columnBytes(statement, column)),
            }
            lua.setField(-2, std.mem.span(c.sqlite3_column_name(statement, column)));
        }
    }

    fn columnBytes(statement: *c.sqlite3_stmt, column: i32) []const u8 {
        // sqlite3_column_bytes must follow sqlite3_column_blob: the blob call can change the length.
        const maybe_bytes: ?[*]const u8 = @ptrCast(c.sqlite3_column_blob(statement, column));
        const length: usize = @intCast(c.sqlite3_column_bytes(statement, column));
        const bytes = maybe_bytes orelse return "";

        return bytes[0..length];
    }

    fn raiseDatabase(lua: *Lua, handle: *c.sqlite3, maybe_statement: ?*c.sqlite3_stmt) noreturn {
        var buffer: [512]u8 = undefined;
        const message = copyMessage(&buffer, c.sqlite3_errmsg(handle));
        _ = c.sqlite3_finalize(maybe_statement);
        raise.formatted(lua, "ulsp.sqlite: {s}", .{message});
    }

    fn copyMessage(buffer: []u8, maybe_message: [*c]const u8) []const u8 {
        if (maybe_message == null) {
            return "unknown error";
        }

        const message = std.mem.span(maybe_message);
        const length = @min(message.len, buffer.len);
        @memcpy(buffer[0..length], message[0..length]);

        return buffer[0..length];
    }
};

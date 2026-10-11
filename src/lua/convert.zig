//! The bridge between Lua and the outside: JSON <-> Lua conversion, the shape
//! tags, JSON text validation, raising Lua errors and converting positions.
const std = @import("std");
const zlua = @import("zlua");
const Document = @import("../text.zig").Document;

const Lua = zlua.Lua;
const json = std.json;
const Allocator = std.mem.Allocator;

/// Raising Lua errors. A raise longjmps over `defer`: release everything first.
pub const raise = struct {
    pub fn text(lua: *Lua, message: []const u8) noreturn {
        _ = lua.pushString(message);
        lua.raiseError();
    }

    pub fn formatted(lua: *Lua, comptime format: []const u8, args: anytype) noreturn {
        var buffer: [512]u8 = undefined;
        text(lua, std.fmt.bufPrint(&buffer, format, args) catch &buffer);
    }
};

/// The shape metatables that mark a Lua table as a JSON array or object, kept as registry
/// references (never as string keys).
pub const Tags = struct {
    array_ref: i32,
    object_ref: i32,

    pub fn init(lua: *Lua) Tags {
        var tags: Tags = undefined;

        lua.createTable(0, 0);
        tags.array_ref = lua.ref(zlua.registry_index);
        lua.createTable(0, 0);
        tags.object_ref = lua.ref(zlua.registry_index);

        return tags;
    }

    pub fn deinit(tags: Tags, lua: *Lua) void {
        lua.unref(zlua.registry_index, tags.array_ref);
        lua.unref(zlua.registry_index, tags.object_ref);
    }

    pub fn push(tags: Tags, lua: *Lua, is_array: bool) void {
        const reference = if (is_array) tags.array_ref else tags.object_ref;
        _ = lua.getIndexRaw(zlua.registry_index, reference);
    }

    pub const Shape = enum { none, array, object };

    /// The shape tag of the table at `index`, `.none` when it has another metatable or none.
    pub fn shapeOf(tags: Tags, lua: *Lua, index: i32) Shape {
        lua.getMetatable(index) catch return .none;
        defer lua.pop(1);

        tags.push(lua, true);
        const is_array = lua.equalRaw(-1, -2);
        lua.pop(1);
        if (is_array) {
            return .array;
        }

        tags.push(lua, false);
        const is_object = lua.equalRaw(-1, -2);
        lua.pop(1);
        if (is_object) {
            return .object;
        }

        return .none;
    }
};

/// Converting `{line, character}` between Lua tables and `Document.Position`.
pub const positions = struct {
    pub fn read(lua: *Lua, index: i32) Document.Position {
        lua.checkType(index, .table);
        _ = lua.getField(index, "line");
        _ = lua.getField(index, "character");

        const line = lua.toInteger(-2) catch raise.text(lua, "ulsp: position.line must be an integer");
        const character = lua.toInteger(-1) catch raise.text(lua, "ulsp: position.character must be an integer");
        lua.pop(2);

        return .{
            .line = @intCast(std.math.clamp(line, 0, std.math.maxInt(u32))),
            .character = @intCast(std.math.clamp(character, 0, std.math.maxInt(u32))),
        };
    }

    pub fn push(lua: *Lua, position: Document.Position) void {
        lua.createTable(0, 2);
        lua.pushInteger(position.line);
        lua.setField(-2, "line");
        lua.pushInteger(position.character);
        lua.setField(-2, "character");
    }

    pub fn pushRange(lua: *Lua, range: Document.Range) void {
        lua.createTable(0, 2);
        positions.push(lua, range.start);
        lua.setField(-2, "start");
        positions.push(lua, range.end);
        lua.setField(-2, "end");
    }
};

/// Nesting limit for JSON text: bounds the stack and memory a hostile `[[[[...` input can make
/// the parser use.
pub const max_json_depth = 128;

pub fn isNestingWithinLimit(bytes: []const u8) bool {
    var depth: usize = 0;
    var in_string = false;
    var index: usize = 0;

    while (index < bytes.len) : (index += 1) {
        const byte = bytes[index];

        if (in_string) {
            if (byte == '\\') {
                index += 1;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }

        switch (byte) {
            '"' => in_string = true,
            '[', '{' => {
                depth += 1;
                if (depth > max_json_depth) {
                    return false;
                }
            },
            ']', '}' => depth -|= 1,
            else => {},
        }
    }

    return true;
}

test "nesting prescan" {
    try std.testing.expect(isNestingWithinLimit("{\"a\":[1,2,{\"b\":\"[[[[\\\"[\"}]}"));

    var deep: [200]u8 = undefined;
    @memset(&deep, '[');
    try std.testing.expect(!isNestingWithinLimit(&deep));
}

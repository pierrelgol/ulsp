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

pub const max_depth = 64;

pub const Error = error{ UnsupportedType, DepthExceeded, InvalidUtf8, OutOfMemory };

/// The address of this byte is `ulsp.null`.
const null_sentinel: u8 = 0;

pub fn pushNull(lua: *Lua) void {
    lua.pushLightUserdata(&null_sentinel);
}

/// Pushes `value`. Fails, leaving the stack as it was, if nesting exceeds `max_depth`.
pub fn push(lua: *Lua, tags: Tags, value: json.Value) Error!void {
    return pushAtDepth(lua, tags, value, 0);
}

/// Reads the Lua value at `index`. Allocates only from `arena`. Does not raise Lua errors.
pub fn toJson(lua: *Lua, tags: Tags, arena: Allocator, index: i32) Error!json.Value {
    return toJsonAtDepth(lua, tags, arena, index, 0);
}

pub fn errorText(err: Error) [:0]const u8 {
    return switch (err) {
        error.UnsupportedType => "cannot convert value to JSON: unsupported type or non-string key",
        error.DepthExceeded => "cannot convert value to JSON: nesting too deep",
        error.InvalidUtf8 => "cannot convert value to JSON: string is not valid UTF-8",
        error.OutOfMemory => "out of memory",
    };
}

fn isNull(lua: *Lua, index: i32) bool {
    return lua.typeOf(index) == .light_userdata and lua.toPointer(index) == @as(*const anyopaque, &null_sentinel);
}

fn pushAtDepth(lua: *Lua, tags: Tags, value: json.Value, depth: u32) Error!void {
    if (depth > max_depth) {
        return error.DepthExceeded;
    }
    lua.checkStack(6) catch return error.OutOfMemory;

    const top = lua.getTop();
    errdefer lua.setTop(top);

    switch (value) {
        .null => pushNull(lua),
        .bool => |boolean| lua.pushBoolean(boolean),
        .integer => |integer| lua.pushInteger(integer),
        .float => |float| lua.pushNumber(float),
        .number_string => |digits| lua.pushNumber(std.fmt.parseFloat(f64, digits) catch 0),
        .string => |text| _ = lua.pushString(text),
        .array => |array| {
            lua.createTable(@intCast(array.items.len), 0);
            for (array.items, 1..) |item, position| {
                try pushAtDepth(lua, tags, item, depth + 1);
                lua.setIndex(-2, @intCast(position));
            }
            tags.push(lua, true);
            lua.setMetatable(-2);
        },
        .object => |object| {
            lua.createTable(0, @intCast(object.count()));
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                _ = lua.pushString(entry.key_ptr.*);
                try pushAtDepth(lua, tags, entry.value_ptr.*, depth + 1);
                lua.setTable(-3);
            }
            tags.push(lua, false);
            lua.setMetatable(-2);
        },
    }
}

fn toJsonAtDepth(lua: *Lua, tags: Tags, arena: Allocator, index: i32, depth: u32) Error!json.Value {
    if (depth > max_depth) {
        return error.DepthExceeded;
    }

    const absolute_index = lua.absIndex(index);
    switch (lua.typeOf(absolute_index)) {
        .none, .nil => return .null,
        .boolean => return .{ .bool = lua.toBoolean(absolute_index) },
        .number => return numberToJson(lua, absolute_index),
        .string => {
            const text = lua.toString(absolute_index) catch unreachable;
            if (!std.unicode.utf8ValidateSlice(text)) {
                return error.InvalidUtf8;
            }

            return .{ .string = try arena.dupe(u8, text) };
        },
        .light_userdata => {
            if (isNull(lua, absolute_index)) {
                return .null;
            }

            return error.UnsupportedType;
        },
        .table => return tableToJson(lua, tags, arena, absolute_index, depth),
        else => return error.UnsupportedType,
    }
}

/// Integers stay integers; a float with an integral value becomes one; NaN and infinity are null.
fn numberToJson(lua: *Lua, absolute_index: i32) json.Value {
    if (lua.isInteger(absolute_index)) {
        return .{ .integer = lua.toInteger(absolute_index) catch unreachable };
    }

    const number = lua.toNumber(absolute_index) catch unreachable;
    if (!std.math.isFinite(number)) {
        return .null;
    }
    if (@floor(number) == number and @abs(number) < 9.0e18) {
        return .{ .integer = @intFromFloat(number) };
    }

    return .{ .float = number };
}

fn tableToJson(lua: *Lua, tags: Tags, arena: Allocator, absolute_index: i32, depth: u32) Error!json.Value {
    lua.checkStack(6) catch return error.OutOfMemory;

    const length = lua.lenRaw(absolute_index);
    var shape = tags.shapeOf(lua, absolute_index);
    if (shape == .none) {
        const is_sequence = length > 0 and isSequence(lua, absolute_index, length);
        shape = if (is_sequence) .array else .object;
    }

    if (shape == .array) {
        return arrayToJson(lua, tags, arena, absolute_index, length, depth);
    }

    return objectToJson(lua, tags, arena, absolute_index, depth);
}

fn arrayToJson(lua: *Lua, tags: Tags, arena: Allocator, absolute_index: i32, length: usize, depth: u32) Error!json.Value {
    var array: json.Array = .init(arena);

    var position: usize = 1;
    while (position <= length) : (position += 1) {
        _ = lua.getIndexRaw(absolute_index, @intCast(position));
        defer lua.pop(1);

        try array.append(try toJsonAtDepth(lua, tags, arena, -1, depth + 1));
    }

    return .{ .array = array };
}

fn objectToJson(lua: *Lua, tags: Tags, arena: Allocator, absolute_index: i32, depth: u32) Error!json.Value {
    var object: json.ObjectMap = .empty;

    lua.pushNil();
    while (lua.next(absolute_index)) {
        // On an error the iteration is abandoned with key and value still on the stack.
        errdefer lua.pop(2);

        // Key at -2, value at -1. Never call toString on a non-string key: it would convert it
        // in place.
        if (lua.typeOf(-2) != .string) {
            return error.UnsupportedType;
        }

        const key = try arena.dupe(u8, lua.toString(-2) catch unreachable);
        const value = try toJsonAtDepth(lua, tags, arena, -1, depth + 1);
        if (!std.unicode.utf8ValidateSlice(key)) {
            return error.InvalidUtf8;
        }

        try object.put(arena, key, value);
        lua.pop(1);
    }

    return .{ .object = object };
}

/// True when the table holds exactly the keys 1..length.
fn isSequence(lua: *Lua, absolute_index: i32, length: usize) bool {
    var key_count: usize = 0;

    lua.pushNil();
    while (lua.next(absolute_index)) {
        key_count += 1;

        const is_position = lua.isInteger(-2) and blk: {
            const key = lua.toInteger(-2) catch unreachable;
            break :blk key >= 1 and key <= length;
        };
        if (!is_position) {
            lua.pop(2);
            return false;
        }

        lua.pop(1);
    }

    return key_count == length;
}

const testing = std.testing;

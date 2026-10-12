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

fn encodeArgument(lua: *Lua, runtime: *Runtime) []u8 {
    lua.checkAny(1);

    var arena: std.heap.ArenaAllocator = .init(runtime.gpa);
    const encoded: convert.Error![]u8 = blk: {
        defer arena.deinit();

        const value = convert.toJson(lua, runtime.tags, arena.allocator(), 1) catch |err| break :blk err;

        break :blk std.json.Stringify.valueAlloc(runtime.gpa, value, .{}) catch error.OutOfMemory;
    };

    return encoded catch |err| raise.text(lua, convert.errorText(err));
}

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

pub const operation_calls = struct {
    const RunSpecError = error{ BadCommand, BadStdin, BadCwd, BadEnvironment, OutOfMemory };

    pub fn startSleep(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const milliseconds = lua.checkNumber(1);
        if (std.math.isNan(milliseconds) or milliseconds < 0) {
            lua.argError(1, "expected a number >= 0");
        }

        return startOperation(lua, runtime, .init(runtime.gpa), .{ .sleep = @intFromFloat(@min(milliseconds, operations.max_sleep_ms)) });
    }

    pub fn startPathOperation(comptime kind: []const u8) fn (*Lua) i32 {
        return struct {
            fn start(lua: *Lua) i32 {
                const runtime = Runtime.of(lua);
                const path = lua.checkString(1);

                var arena: Arena = .init(runtime.gpa);
                const spec = @unionInit(operations.Spec, kind, copyOrRaise(lua, &arena, path));

                return startOperation(lua, runtime, arena, spec);
            }
        }.start;
    }

    pub fn startWrite(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const path = lua.checkString(1);
        const data = lua.checkString(2);

        var arena: Arena = .init(runtime.gpa);
        const spec: operations.Spec = .{ .write = .{
            .path = copyOrRaise(lua, &arena, path),
            .data = copyOrRaise(lua, &arena, data),
        } };

        return startOperation(lua, runtime, arena, spec);
    }

    pub fn startRun(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        lua.checkType(1, .table);

        var arena: Arena = .init(runtime.gpa);
        const spec = readRunSpec(lua, arena.allocator()) catch |err| {
            arena.deinit();
            raise.text(lua, runSpecErrorText(err));
        };

        return startOperation(lua, runtime, arena, .{ .run = spec });
    }

    pub fn cancel(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const id = lua.checkInteger(1);

        if (id > 0) {
            runtime.operation_table.cancel(@intCast(id));
        }

        return 0;
    }

    fn startOperation(lua: *Lua, runtime: *Runtime, arena: Arena, spec: operations.Spec) i32 {
        const id = runtime.operation_table.start(arena, spec) catch |err| {
            raise.formatted(lua, "ulsp: cannot start operation: {s}", .{@errorName(err)});
        };
        lua.pushInteger(@intCast(id));

        return 1;
    }

    fn copyOrRaise(lua: *Lua, arena: *Arena, text: []const u8) []const u8 {
        return arena.allocator().dupe(u8, text) catch {
            arena.deinit();
            raise.text(lua, "out of memory");
        };
    }

    fn runSpecErrorText(err: RunSpecError) []const u8 {
        return switch (err) {
            error.BadCommand => "ulsp.process.run: cmd must be an array of strings with at least one element",
            error.BadStdin => "ulsp.process.run: stdin must be a string",
            error.BadCwd => "ulsp.process.run: cwd must be a string",
            error.BadEnvironment => "ulsp.process.run: env must be a table of strings",
            error.OutOfMemory => "out of memory",
        };
    }

    fn readRunSpec(lua: *Lua, arena: Allocator) RunSpecError!RunSpec {
        lua.checkStack(8) catch return error.OutOfMemory;

        const argv = try readCommand(lua, arena);
        const stdin = try readOptionalString(lua, arena, "stdin", error.BadStdin);
        const cwd = try readOptionalString(lua, arena, "cwd", error.BadCwd);
        const environment = try readEnvironment(lua, arena);

        return .{ .argv = argv, .stdin = stdin, .cwd = cwd, .environment = environment };
    }

    fn readCommand(lua: *Lua, arena: Allocator) RunSpecError![]const []const u8 {
        if (lua.getField(1, "cmd") != .table) {
            return error.BadCommand;
        }

        var argv: std.ArrayList([]const u8) = .empty;
        for (1..lua.lenRaw(-1) + 1) |position| {
            _ = lua.getIndexRaw(-1, @intCast(position));
            if (lua.typeOf(-1) != .string) {
                return error.BadCommand;
            }

            try argv.append(arena, try arena.dupe(u8, lua.toString(-1) catch unreachable));
            lua.pop(1);
        }
        lua.pop(1);

        if (argv.items.len == 0) {
            return error.BadCommand;
        }

        return argv.items;
    }

    fn readOptionalString(lua: *Lua, arena: Allocator, name: [:0]const u8, bad_type: RunSpecError) RunSpecError!?[]const u8 {
        defer lua.pop(1);

        return switch (lua.getField(1, name)) {
            .nil => null,
            .string => try arena.dupe(u8, lua.toString(-1) catch unreachable),
            else => bad_type,
        };
    }

    fn readEnvironment(lua: *Lua, arena: Allocator) RunSpecError![]const [2][]const u8 {
        defer lua.pop(1);

        var entries: std.ArrayList([2][]const u8) = .empty;
        switch (lua.getField(1, "env")) {
            .nil => {},
            .table => {
                lua.pushNil();
                while (lua.next(-2)) {
                    if (lua.typeOf(-2) != .string or lua.typeOf(-1) != .string) {
                        return error.BadEnvironment;
                    }

                    try entries.append(arena, .{
                        try arena.dupe(u8, lua.toString(-2) catch unreachable),
                        try arena.dupe(u8, lua.toString(-1) catch unreachable),
                    });
                    lua.pop(1);
                }
            },
            else => return error.BadEnvironment,
        }

        return entries.items;
    }
};

pub const operation_results = struct {
    pub fn push(lua: *Lua, runtime: *Runtime, result: operations.Result) void {
        lua.checkStack(8) catch return lua.pushNil();

        switch (result) {
            .pending, .failed => unreachable,
            .completed => lua.pushBoolean(true),
            .bytes => |bytes| _ = lua.pushString(bytes),
            .process => |process| pushProcess(lua, process),
            .stat => |maybe_stat| {
                if (maybe_stat) |stat| {
                    pushStat(lua, stat);
                } else {
                    lua.pushBoolean(false);
                }
            },
            .list => |entries| pushList(lua, runtime, entries),
        }
    }

    fn pushProcess(lua: *Lua, process: ProcessResult) void {
        lua.createTable(0, 4);

        if (process.exit_code) |exit_code| {
            lua.pushInteger(exit_code);
            lua.setField(-2, "code");
        }
        if (process.signal) |signal| {
            lua.pushInteger(signal);
            lua.setField(-2, "signal");
        }

        _ = lua.pushString(process.stdout);
        lua.setField(-2, "stdout");
        _ = lua.pushString(process.stderr);
        lua.setField(-2, "stderr");
    }

    fn pushStat(lua: *Lua, stat: FileStat) void {
        lua.createTable(0, 3);

        _ = lua.pushString(stat.kind);
        lua.setField(-2, "kind");
        lua.pushInteger(@intCast(stat.size));
        lua.setField(-2, "size");
        lua.pushInteger(stat.mtime_ms);
        lua.setField(-2, "mtime");
    }

    fn pushList(lua: *Lua, runtime: *Runtime, entries: []const DirectoryEntry) void {
        lua.createTable(@intCast(entries.len), 0);

        for (entries, 1..) |entry, position| {
            lua.createTable(0, 2);
            _ = lua.pushString(entry.name);
            lua.setField(-2, "name");
            _ = lua.pushString(entry.kind);
            lua.setField(-2, "kind");
            lua.setIndex(-2, @intCast(position));
        }

        runtime.tags.push(lua, true);
        lua.setMetatable(-2);
    }
};

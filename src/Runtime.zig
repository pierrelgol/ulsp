const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const zlua = @import("zlua");
const Lua = zlua.Lua;

const core = @import("lua.zig").core;
const document_calls = core.document_calls;
const embedded_lua = core.embedded_lua;
const lua_calls = core.lua_calls;
const DocumentStore = @import("text.zig").DocumentStore;
const Operation = @import("ops.zig").Operation;
const operations = @import("ops.zig");
const OperationTable = @import("ops.zig").OperationTable;
const Tags = @import("lua.zig").convert.Tags;
const transport = @import("transport.zig");
const ClientWriter = transport.ClientWriter;
const Trees = @import("syntax.zig").Trees;

const Runtime = @This();

const native_gc_threshold_bytes = 64 * 1024 * 1024;
const log_level_names = [_][]const u8{ "error", "warn", "info", "debug" };
const max_log_line_bytes = 4096;

pub const Hooks = struct {
    on_message: *const fn (*Runtime, []const u8) void,
    reject: *const fn (*Runtime, std.json.Value, []const u8) void,
};

pub const StartError = error{
    OutOfMemory,
    EmbeddedLuaFailed,
};

gpa: Allocator,
io: Io,
environ: *const std.process.Environ.Map,
lua: *Lua,
tags: Tags,
queue_storage: [operations.queue_capacity]operations.Event = undefined,
queue: operations.EventQueue = undefined,
operation_table: OperationTable = undefined,
documents: DocumentStore,
trees: Trees,
client_writer: *ClientWriter,
hooks: Hooks,
exit_code: ?u8 = null,
native_bytes_since_collection: usize = 0,
document_metatable_ref: i32 = 0,
on_message_ref: i32 = 0,
on_completion_ref: i32 = 0,

pub fn of(lua: *Lua) *Runtime {
    const extra_space = lua.getExtraSpace();

    return std.mem.bytesToValue(*Runtime, extra_space[0..@sizeOf(*Runtime)]);
}

pub fn create(gpa: Allocator, io: Io, environ: *const std.process.Environ.Map, client_writer: *ClientWriter, hooks: Hooks) StartError!*Runtime {
    const runtime = try gpa.create(Runtime);
    errdefer gpa.destroy(runtime);
    const lua = try Lua.init(gpa);
    errdefer lua.deinit();

    runtime.* = .{
        .gpa = gpa,
        .io = io,
        .environ = environ,
        .lua = lua,
        .tags = undefined,
        .documents = .{ .gpa = gpa },
        .trees = .{ .gpa = gpa },
        .client_writer = client_writer,
        .hooks = hooks,
    };
    runtime.queue = .init(&runtime.queue_storage);
    runtime.operation_table.init(gpa, io, &runtime.queue, environ);

    const runtime_pointer: *Runtime = runtime;
    @memcpy(lua.getExtraSpace()[0..@sizeOf(*Runtime)], std.mem.asBytes(&runtime_pointer));

    lua.openLibs();
    runtime.tags = .init(lua);
    errdefer runtime.tags.deinit(lua);

    document_calls.pushMetatable(lua);
    runtime.document_metatable_ref = lua.ref(zlua.registry_index);
    core.push(lua);
    embedded_lua.load(runtime) catch |err| {
        lua_calls.logLuaError(runtime, "embedded Lua failed to load");
        return err;
    };

    return runtime;
}

pub fn destroy(runtime: *Runtime) void {
    const gpa = runtime.gpa;

    runtime.operation_table.deinit();
    runtime.tags.deinit(runtime.lua);
    runtime.lua.deinit();
    runtime.documents.deinit();
    runtime.trees.deinit();
    gpa.destroy(runtime);
}

pub fn shutdown(runtime: *Runtime, reader: *Io.Future(void)) void {
    runtime.operation_table.cancelAll();
    reader.cancel(runtime.io);
    runtime.drainQueue();
}

pub fn log(_: *Runtime, level: u8, text: []const u8) void {
    const level_name = log_level_names[std.math.clamp(level, 1, 4) - 1];

    var buffer: [max_log_line_bytes]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "ulsp [{s}] {s}\n", .{ level_name, text }) catch cut: {
        buffer[buffer.len - 1] = '\n';
        break :cut buffer[0..];
    };

    transport.writeStderrNonBlocking(line);
}

pub fn noteNativeBytes(runtime: *Runtime, byte_count: usize) void {
    runtime.native_bytes_since_collection += byte_count;
    if (runtime.native_bytes_since_collection < native_gc_threshold_bytes) {
        return;
    }

    runtime.native_bytes_since_collection = 0;
    runtime.lua.gcCollect();
}

pub fn run(runtime: *Runtime) u8 {
    while (true) {
        const pass_start_ns = runtime.operation_table.now();
        while (runtime.operation_table.popDueTimer(pass_start_ns)) |operation| {
            runtime.deliverTimer(operation);
            if (runtime.exit_code) |code| {
                return code;
            }
        }

        runtime.operation_table.armWake();
        const event = runtime.queue.getOneUncancelable(runtime.io) catch return runtime.exit_code orelse 1;
        if (!runtime.handleEvent(event)) {
            return runtime.exit_code.?;
        }
    }
}

fn handleEvent(runtime: *Runtime, event: operations.Event) bool {
    switch (event) {
        .message => |bytes| {
            defer runtime.gpa.free(bytes);
            runtime.hooks.on_message(runtime, bytes);
        },
        .completion => |operation| runtime.deliverCompletion(operation),
        .tick => runtime.operation_table.disarmWake(),
        .eof => {
            if (runtime.exit_code == null) {
                runtime.exit_code = 1;
            }
        },
    }

    return runtime.exit_code == null;
}

fn deliverCompletion(runtime: *Runtime, operation: *Operation) void {
    runtime.operation_table.takeCompleted(operation);
    defer runtime.operation_table.destroyOperation(operation);

    if (operation.detached) {
        return;
    }
    lua_calls.callOnCompletion(runtime, operation);
}

fn deliverTimer(runtime: *Runtime, operation: *Operation) void {
    defer runtime.operation_table.destroyOperation(operation);
    lua_calls.callOnCompletion(runtime, operation);
}

fn drainQueue(runtime: *Runtime) void {
    var slot: [1]operations.Event = undefined;
    while ((runtime.queue.get(runtime.io, &slot, 0) catch 0) == 1) {
        switch (slot[0]) {
            .message => |bytes| runtime.gpa.free(bytes),
            .completion => |operation| {
                runtime.operation_table.takeCompleted(operation);
                runtime.operation_table.destroyOperation(operation);
            },
            .tick, .eof => {},
        }
    }
}

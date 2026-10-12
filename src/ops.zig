const std = @import("std");
pub const work = @import("work.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const queue_capacity = 64;
pub const max_process_output_bytes = 16 * 1024 * 1024;
pub const max_read_bytes = 64 * 1024 * 1024;
pub const max_sleep_ms = 1 << 40;
pub const max_workers = 32;

pub const Event = union(enum) {
    message: []u8,
    completion: *Operation,
    tick,
    eof,
};

pub const EventQueue = std.Io.Queue(Event);

pub const Spec = union(enum) {
    sleep: u64,
    run: RunSpec,
    read: []const u8,
    write: struct { path: []const u8, data: []const u8 },
    stat: []const u8,
    list: []const u8,
};

pub const Result = union(enum) {
    pending,
    completed,
    bytes: []const u8,
    process: ProcessResult,
    stat: ?FileStat,
    list: []DirectoryEntry,
    failed: []const u8,
};

pub const RunSpec = struct {
    argv: []const []const u8,
    stdin: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    environment: []const [2][]const u8 = &.{},
};
pub const ProcessResult = struct {
    exit_code: ?u8,
    signal: ?u32,
    stdout: []const u8,
    stderr: []const u8,
};

pub const FileStat = struct {
    kind: []const u8,
    size: u64,
    mtime_ms: i64,
};

pub const DirectoryEntry = struct {
    name: []const u8,
    kind: []const u8,
};

pub const Timer = struct {
    deadline_ns: i96,
    operation: *Operation,
};

pub const Operation = struct {
    id: u64,
    arena: std.heap.ArenaAllocator,
    spec: Spec,
    result: Result = .pending,
    future: std.Io.Future(void) = undefined,
    posted: bool = false,
    detached: bool = false,
    holds_slot: bool = false,
    table: *OperationTable,
};

pub const OperationTable = struct {
    gpa: Allocator,
    io: Io,
    queue: *EventQueue,
    environ: *const std.process.Environ.Map,
    next_id: u64 = 1,
    operations_by_id: std.AutoHashMapUnmanaged(u64, *Operation) = .empty,
    timers: std.ArrayList(Timer) = .empty,
    wake_future: ?Io.Future(void) = null,
    armed_deadline_ns: i96 = 0,
    slot_storage: [max_workers]u8 = undefined,
    slots: Io.Queue(u8) = undefined,

    pub fn init(table: *OperationTable, gpa: Allocator, io: Io, queue: *EventQueue, environ: *const std.process.Environ.Map) void {
        table.* = .{
            .gpa = gpa,
            .io = io,
            .queue = queue,
            .environ = environ,
        };
        table.slots = .init(&table.slot_storage);

        const all_slots_free: [max_workers]u8 = @splat(0);
        _ = table.slots.putUncancelable(io, &all_slots_free, max_workers) catch unreachable;
    }

    pub fn deinit(table: *OperationTable) void {
        table.cancelAll();

        var iterator = table.operations_by_id.valueIterator();
        while (iterator.next()) |operation| {
            table.destroyOperation(operation.*);
        }
        table.operations_by_id.deinit(table.gpa);
        table.timers.deinit(table.gpa);
    }

    pub fn start(table: *OperationTable, arena: std.heap.ArenaAllocator, spec: Spec) !u64 {
        const operation = table.gpa.create(Operation) catch |err| {
            arena.deinit();
            return err;
        };
        operation.* = .{ .id = table.next_id, .arena = arena, .spec = spec, .table = table };
        errdefer table.destroyOperation(operation);

        try table.operations_by_id.put(table.gpa, operation.id, operation);
        errdefer _ = table.operations_by_id.remove(operation.id);

        if (spec == .sleep) {
            try table.insertTimer(operation, spec.sleep);
        } else {
            operation.future = try table.io.concurrent(work.run, .{operation});
        }

        table.next_id += 1;

        return operation.id;
    }

    pub fn cancel(table: *OperationTable, id: u64) void {
        const operation = table.operations_by_id.get(id) orelse return;
        operation.detached = true;

        if (operation.spec == .sleep) {
            table.removeTimer(operation);
            _ = table.operations_by_id.remove(id);
            table.destroyOperation(operation);
            return;
        }

        operation.future.cancel(table.io);
        table.releaseSlot(operation);

        if (!operation.posted) {
            _ = table.operations_by_id.remove(id);
            table.destroyOperation(operation);
        }
    }

    pub fn cancelAll(table: *OperationTable) void {
        table.disarmWake();
        table.timers.clearRetainingCapacity();

        var iterator = table.operations_by_id.valueIterator();
        while (iterator.next()) |operation| {
            operation.*.detached = true;
            if (operation.*.spec != .sleep) {
                operation.*.future.cancel(table.io);
            }
        }

        while (table.firstUnposted()) |operation| {
            _ = table.operations_by_id.remove(operation.id);
            table.destroyOperation(operation);
        }
    }

    pub fn now(table: *const OperationTable) i96 {
        return Io.Clock.awake.now(table.io).nanoseconds;
    }

    pub fn popDueTimer(table: *OperationTable, at_ns: i96) ?*Operation {
        if (table.timers.items.len == 0 or table.timers.items[0].deadline_ns > at_ns) {
            return null;
        }

        const operation = table.timers.orderedRemove(0).operation;
        _ = table.operations_by_id.remove(operation.id);
        operation.result = .completed;

        return operation;
    }

    pub fn armWake(table: *OperationTable) void {
        if (table.timers.items.len == 0) {
            return table.disarmWake();
        }

        const earliest_deadline_ns = table.timers.items[0].deadline_ns;
        if (table.wake_future != null and table.armed_deadline_ns == earliest_deadline_ns) {
            return;
        }

        table.disarmWake();
        table.armed_deadline_ns = earliest_deadline_ns;
        table.wake_future = table.io.concurrent(postTickAt, .{ table, earliest_deadline_ns }) catch null;
    }

    pub fn disarmWake(table: *OperationTable) void {
        if (table.wake_future) |*wake_future| {
            wake_future.cancel(table.io);
        }
        table.wake_future = null;
    }

    pub fn takeCompleted(table: *OperationTable, operation: *Operation) void {
        operation.future.await(table.io);
        table.releaseSlot(operation);
        _ = table.operations_by_id.remove(operation.id);
    }

    pub fn destroyOperation(table: *OperationTable, operation: *Operation) void {
        operation.arena.deinit();
        table.gpa.destroy(operation);
    }

    fn releaseSlot(table: *OperationTable, operation: *Operation) void {
        if (!operation.holds_slot) {
            return;
        }

        operation.holds_slot = false;
        table.slots.putOneUncancelable(table.io, 0) catch unreachable;
    }

    fn insertTimer(table: *OperationTable, operation: *Operation, milliseconds: u64) !void {
        const delay_ns = @as(i96, milliseconds) * std.time.ns_per_ms;
        const deadline_ns = table.now() + delay_ns;

        var insert_index = table.timers.items.len;
        while (insert_index > 0 and table.timers.items[insert_index - 1].deadline_ns > deadline_ns) {
            insert_index -= 1;
        }

        try table.timers.insert(table.gpa, insert_index, .{ .deadline_ns = deadline_ns, .operation = operation });
    }

    fn removeTimer(table: *OperationTable, operation: *Operation) void {
        for (table.timers.items, 0..) |timer, index| {
            if (timer.operation == operation) {
                _ = table.timers.orderedRemove(index);
                return;
            }
        }
    }

    fn firstUnposted(table: *OperationTable) ?*Operation {
        var iterator = table.operations_by_id.valueIterator();
        while (iterator.next()) |operation| {
            if (!operation.*.posted) {
                return operation.*;
            }
        }

        return null;
    }

    fn postTickAt(table: *OperationTable, deadline_ns: i96) void {
        while (table.now() < deadline_ns) {
            table.io.sleep(.fromNanoseconds(deadline_ns - table.now()), .awake) catch return;
        }
        table.queue.putOne(table.io, .tick) catch {};
    }
};

pub const TestHarness = struct {
    queue_storage: [queue_capacity]Event = undefined,
    queue: EventQueue = undefined,
    environ: std.process.Environ.Map,
    table: OperationTable = undefined,

    pub fn init(harness: *TestHarness) void {
        harness.environ = .init(testing.allocator);
        harness.queue = .init(&harness.queue_storage);
        harness.table.init(testing.allocator, testing.io, &harness.queue, &harness.environ);
    }

    pub fn deinit(harness: *TestHarness) void {
        harness.table.deinit();
        harness.environ.deinit();
    }

    pub fn start(harness: *TestHarness, spec: Spec) !u64 {
        return harness.table.start(.init(testing.allocator), spec);
    }

    pub fn startRun(harness: *TestHarness, argv: []const []const u8) !u64 {
        return harness.start(.{ .run = .{ .argv = argv } });
    }

    pub fn nextCompletion(harness: *TestHarness) !*Operation {
        const event = harness.queue.getOne(testing.io) catch unreachable;
        const operation = event.completion;
        harness.table.takeCompleted(operation);

        return operation;
    }

    pub fn nextDueSleep(harness: *TestHarness) !*Operation {
        while (true) {
            if (harness.table.popDueTimer(harness.table.now())) |operation| {
                return operation;
            }
            try testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
};

const testing = std.testing;

test "sleep completes" {
    var harness: TestHarness = undefined;
    harness.init();
    defer harness.deinit();

    const id = try harness.start(.{ .sleep = 5 });
    const operation = try harness.nextDueSleep();
    defer harness.table.destroyOperation(operation);

    try testing.expectEqual(id, operation.id);
    try testing.expect(operation.result == .completed);
    try testing.expectEqual(@as(usize, 0), harness.table.operations_by_id.count());
}

test "a due sleep wakes the loop with a tick" {
    var harness: TestHarness = undefined;
    harness.init();
    defer harness.deinit();

    _ = try harness.start(.{ .sleep = 5 });
    harness.table.armWake();
    try testing.expect((try harness.queue.getOne(testing.io)) == .tick);

    harness.table.disarmWake();
    harness.table.destroyOperation(harness.table.popDueTimer(harness.table.now()).?);
}

test "cancel before completion leaves nothing" {
    var harness: TestHarness = undefined;
    harness.init();
    defer harness.deinit();

    const id = try harness.start(.{ .sleep = 60_000 });
    harness.table.cancel(id);
    harness.table.cancel(id); // unknown id is ignored

    try testing.expectEqual(@as(usize, 0), harness.table.operations_by_id.count());
}

test "a sleep armed after the cutoff is not due at it" {
    var harness: TestHarness = undefined;
    harness.init();
    defer harness.deinit();

    const cutoff_ns = harness.table.now();
    _ = try harness.start(.{ .sleep = 0 });

    try testing.expect(harness.table.popDueTimer(cutoff_ns) == null);
    harness.table.destroyOperation(harness.table.popDueTimer(harness.table.now()).?);
}

test "timers fire in deadline order, ties in start order, and cancel removes" {
    var harness: TestHarness = undefined;
    harness.init();
    defer harness.deinit();

    const slowest = try harness.start(.{ .sleep = 120 });
    const fastest = try harness.start(.{ .sleep = 10 });
    const middle = try harness.start(.{ .sleep = 60 });
    const canceled = try harness.start(.{ .sleep = 600_000 });
    harness.table.cancel(canceled);
    harness.table.cancel(canceled);
    try testing.expectEqual(@as(usize, 3), harness.table.timers.items.len);

    var fired_order: [3]u64 = undefined;
    for (&fired_order) |*fired_id| {
        const operation = try harness.nextDueSleep();
        fired_id.* = operation.id;
        harness.table.destroyOperation(operation);
    }

    try testing.expectEqualSlices(u64, &.{ fastest, middle, slowest }, &fired_order);
    try testing.expectEqual(@as(usize, 0), harness.table.operations_by_id.count());

    harness.table.timers.clearRetainingCapacity();
    const shared_deadline_ns = harness.table.now() + 10 * std.time.ns_per_ms;
    var tied_operations: [3]*Operation = undefined;

    for (&tied_operations, 0..) |*tied_operation, index| {
        tied_operation.* = try testing.allocator.create(Operation);
        tied_operation.*.* = .{
            .id = 100 + index,
            .arena = .init(testing.allocator),
            .spec = .{ .sleep = 0 },
            .table = &harness.table,
        };

        try harness.table.operations_by_id.put(testing.allocator, tied_operation.*.id, tied_operation.*);
        try harness.table.timers.append(testing.allocator, .{ .deadline_ns = shared_deadline_ns, .operation = tied_operation.* });
    }

    for (0..3) |index| {
        const operation = harness.table.popDueTimer(shared_deadline_ns).?;
        try testing.expectEqual(@as(u64, 100 + index), operation.id);
        harness.table.destroyOperation(operation);
    }
}

//! Operations: slow work done by workers. Never touches Lua.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const work = @import("work.zig");

pub const queue_capacity = 64;
pub const max_process_output_bytes = 16 * 1024 * 1024;
pub const max_read_bytes = 64 * 1024 * 1024;

/// About 34 years: keeps `milliseconds * ns_per_ms` inside the clock's integer.
pub const max_sleep_ms = 1 << 40;

/// Operations running at once (sleeps excluded). The rest wait for a slot inside their task.
pub const max_workers = 32;

pub const Event = union(enum) {
    /// The bytes of one message body, owned by the event.
    message: []u8,
    completion: *Operation,
    /// The wake task of the earliest sleep; the loop then reads the clock and fires due sleeps.
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
    /// `"<ErrorName>: <subject>"`.
    failed: []const u8,
};

/// A process to run, with every string owned by the operation's arena.
pub const RunSpec = struct {
    argv: []const []const u8,
    stdin: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    /// Key, value; added over the server environment.
    environment: []const [2][]const u8 = &.{},
};

/// How a finished process ended and what it wrote.
pub const ProcessResult = struct {
    /// Null when the process did not exit normally.
    exit_code: ?u8,
    /// Null unless a signal ended the process.
    signal: ?u32,
    stdout: []const u8,
    stderr: []const u8,
};

/// What `stat` reports about a path, without following a final symlink.
pub const FileStat = struct {
    kind: []const u8,
    size: u64,
    mtime_ms: i64,
};

/// One name in a directory listing, with its kind as Lua sees it.
pub const DirectoryEntry = struct {
    name: []const u8,
    kind: []const u8,
};

/// A pending sleep: the loop fires it once the clock reaches `deadline_ns`.
pub const Timer = struct {
    deadline_ns: i96,
    operation: *Operation,
};

/// One running or finished operation, owned by an `OperationTable`.
pub const Operation = struct {
    id: u64,
    /// Owns the memory of `spec` and `result`; the worker allocates from it too.
    arena: std.heap.ArenaAllocator,
    spec: Spec,
    result: Result = .pending,
    future: std.Io.Future(void) = undefined,
    posted: bool = false,
    detached: bool = false,
    /// It holds one of the `max_workers` slots until the loop takes or cancels it.
    holds_slot: bool = false,
    table: *OperationTable,
};

/// The operation table. Loop thread only, except that workers read `queue`, `io`, `gpa`,
/// `environ` and `slots`.
pub const OperationTable = struct {
    gpa: Allocator,
    io: Io,
    queue: *EventQueue,
    environ: *const std.process.Environ.Map,
    next_id: u64 = 1,
    operations_by_id: std.AutoHashMapUnmanaged(u64, *Operation) = .empty,
    /// Pending sleeps, earliest deadline first, equal deadlines in start order. A sleep has no
    /// worker; the loop fires it. shortcut: sorted array, O(n) insert and cancel; use a heap
    /// if n reaches thousands.
    timers: std.ArrayList(Timer) = .empty,
    /// Wakes the loop at `armed_deadline_ns`, the earliest deadline. Replaced when that changes.
    wake_future: ?Io.Future(void) = null,
    armed_deadline_ns: i96 = 0,
    /// One token per free slot; a queue hands them out to waiters in arrival order (FIFO).
    slot_storage: [max_workers]u8 = undefined,
    slots: Io.Queue(u8) = undefined,

    /// In place: `slots` points into the table.
    pub fn init(table: *OperationTable, gpa: Allocator, io: Io, queue: *EventQueue, environ: *const std.process.Environ.Map) void {
        table.* = .{ .gpa = gpa, .io = io, .queue = queue, .environ = environ };
        table.slots = .init(&table.slot_storage);

        const all_slots_free: [max_workers]u8 = @splat(0);
        _ = table.slots.putUncancelable(io, &all_slots_free, max_workers) catch unreachable;
    }

    /// Cancels everything and frees the table; operations still queued are destroyed with it.
    pub fn deinit(table: *OperationTable) void {
        table.cancelAll();

        var iterator = table.operations_by_id.valueIterator();
        while (iterator.next()) |operation| {
            table.destroyOperation(operation.*);
        }
        table.operations_by_id.deinit(table.gpa);
        table.timers.deinit(table.gpa);
    }

    /// Takes ownership of `arena`, which holds the memory of `spec`; frees it on failure.
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

    /// After this returns the worker is gone and `on_completion` will not run.
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

    /// Shutdown step 1: cancels every operation. Operations whose completion is already queued
    /// stay in the table so the queue drain can `takeCompleted` them.
    pub fn cancelAll(table: *OperationTable) void {
        table.disarmWake();
        // Their operations are not posted: destroyed below.
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

    /// The earliest sleep due at `at_ns` (a `now()` reading), finished and out of the table, or null.
    /// The caller delivers it and calls `destroyOperation`. Sleeps armed after `at_ns` stay for the
    /// next pass.
    pub fn popDueTimer(table: *OperationTable, at_ns: i96) ?*Operation {
        if (table.timers.items.len == 0 or table.timers.items[0].deadline_ns > at_ns) {
            return null;
        }

        const operation = table.timers.orderedRemove(0).operation;
        _ = table.operations_by_id.remove(operation.id);
        operation.result = .completed;

        return operation;
    }

    /// Makes sure the loop is woken when the earliest sleep is due. Call once per loop pass.
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
        // Null when the task cannot start: the next pass retries.
        table.wake_future = table.io.concurrent(postTickAt, .{ table, earliest_deadline_ns }) catch null;
    }

    /// Call when a tick was dequeued: its wake task is done, so the next `armWake` starts a new one.
    pub fn disarmWake(table: *OperationTable) void {
        if (table.wake_future) |*wake_future| {
            wake_future.cancel(table.io);
        }
        table.wake_future = null;
    }

    /// Finishes a completed operation: frees its slot. The caller owns the operation and calls
    /// `destroyOperation`.
    pub fn takeCompleted(table: *OperationTable, operation: *Operation) void {
        operation.future.await(table.io);
        table.releaseSlot(operation);
        _ = table.operations_by_id.remove(operation.id);
    }

    pub fn destroyOperation(table: *OperationTable, operation: *Operation) void {
        operation.arena.deinit();
        table.gpa.destroy(operation);
    }

    /// Gives back the operation's slot. Call only when its worker is gone.
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

    /// Posts a tick once the clock reached `deadline_ns` (a sleep may return early).
    fn postTickAt(table: *OperationTable, deadline_ns: i96) void {
        while (table.now() < deadline_ns) {
            table.io.sleep(.fromNanoseconds(deadline_ns - table.now()), .awake) catch return;
        }
        table.queue.putOne(table.io, .tick) catch {};
    }
};

/// A table with its own queue and environment, for the operation tests.
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

    /// Starts `spec` in a fresh arena; the table owns it from here.
    pub fn start(harness: *TestHarness, spec: Spec) !u64 {
        return harness.table.start(.init(testing.allocator), spec);
    }

    pub fn startRun(harness: *TestHarness, argv: []const []const u8) !u64 {
        return harness.start(.{ .run = .{ .argv = argv } });
    }

    /// Waits for the next worker completion and takes it; the caller destroys the operation.
    pub fn nextCompletion(harness: *TestHarness) !*Operation {
        const event = harness.queue.getOne(testing.io) catch unreachable;
        const operation = event.completion;
        harness.table.takeCompleted(operation);

        return operation;
    }

    /// Waits until a sleep is due and pops it; the caller destroys the operation.
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

    // Ties: one deadline, start order, whatever the wake order of any task.
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

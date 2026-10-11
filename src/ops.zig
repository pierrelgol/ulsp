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

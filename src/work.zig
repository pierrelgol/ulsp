//! What workers do: the task of one operation, file operations and child
//! processes. Runs off the loop thread.
const std = @import("std");
const ops = @import("ops.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const File = Io.File;
const MultiReader = File.MultiReader;
const Operation = ops.Operation;
const RunSpec = ops.RunSpec;
const ProcessResult = ops.ProcessResult;
const FileStat = ops.FileStat;
const DirectoryEntry = ops.DirectoryEntry;
const TestHarness = ops.TestHarness;
const testing = std.testing;

pub fn run(operation: *Operation) void {
    const table = operation.table;

    _ = table.slots.getOne(table.io) catch return;
    operation.holds_slot = true;

    operation.result = perform(operation) catch |err| switch (err) {
        error.Canceled => return,
        else => failedResult(operation.arena.allocator(), err, subject(operation.spec)) catch return,
    };

    operation.posted = true;
    table.queue.putOne(table.io, .{ .completion = operation }) catch {
        operation.posted = false;
    };
}

fn perform(operation: *Operation) !ops.Result {
    const io = operation.table.io;
    const arena = operation.arena.allocator();

    switch (operation.spec) {
        // A timer of the table, never a worker.
        .sleep => unreachable,
        .run => |spec| return .{ .process = try runProcess(operation, spec) },
        .read => |path| return .{ .bytes = try readFile(io, arena, path) },
        .write => |write| {
            try writeFileAtomic(io, arena, write.path, write.data);

            return .completed;
        },
        .stat => |path| return .{ .stat = try statPath(io, path) },
        .list => |path| return .{ .list = try listDirectory(io, arena, path) },
    }
}

fn failedResult(arena: Allocator, err: anyerror, what: []const u8) Allocator.Error!ops.Result {
    return .{ .failed = try std.fmt.allocPrint(arena, "{s}: {s}", .{ @errorName(err), what }) };
}

fn subject(spec: ops.Spec) []const u8 {
    return switch (spec) {
        .sleep => "sleep",
        .run => |run_spec| run_spec.argv[0],
        .read, .stat, .list => |path| path,
        .write => |write| write.path,
    };
}

pub fn readFile(io: Io, arena: Allocator, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(ops.max_read_bytes));
}

/// Temp file + rename: a cancel mid-write leaves the old file intact. A symlink is followed so
/// the rename replaces the target, not the link.
pub fn writeFileAtomic(io: Io, arena: Allocator, path: []const u8, data: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const target_path = cwd.realPathFileAlloc(io, path, arena) catch path;

    var permissions = File.Permissions.default_file;
    if (cwd.statFile(io, target_path, .{})) |existing| {
        permissions = existing.permissions;
    } else |_| {}

    var atomic = try cwd.createFileAtomic(io, target_path, .{ .permissions = permissions, .replace = true });
    defer atomic.deinit(io);

    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    writer.interface.writeAll(data) catch return writer.err.?;
    writer.interface.flush() catch return writer.err.?;

    try atomic.replace(io);
}

/// Null when the path does not exist. Symlinks are not followed.
pub fn statPath(io: Io, path: []const u8) !?FileStat {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    return .{
        .kind = kindName(stat.kind),
        .size = stat.size,
        .mtime_ms = @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_ms)),
    };
}

/// The entries of `path`, sorted by name.
pub fn listDirectory(io: Io, arena: Allocator, path: []const u8) ![]DirectoryEntry {
    var directory = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer directory.close(io);

    var entries: std.ArrayList(DirectoryEntry) = .empty;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        try entries.append(arena, .{ .name = try arena.dupe(u8, entry.name), .kind = kindName(entry.kind) });
    }

    std.mem.sort(DirectoryEntry, entries.items, {}, entryNameLessThan);

    return entries.items;
}

fn entryNameLessThan(_: void, left: DirectoryEntry, right: DirectoryEntry) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn kindName(kind: File.Kind) []const u8 {
    return switch (kind) {
        .file => "file",
        .directory => "directory",
        .sym_link => "symlink",
        else => "other",
    };
}

/// Whatever happens, the child and its group are gone when this returns.
pub fn runProcess(operation: *Operation, spec: RunSpec) !ProcessResult {
    const table = operation.table;
    const gpa = table.gpa;
    const io = table.io;

    var environment = try table.environ.clone(gpa);
    defer environment.deinit();
    for (spec.environment) |entry| {
        try environment.put(entry[0], entry[1]);
    }

    var child = try std.process.spawn(io, .{
        .argv = spec.argv,
        .cwd = if (spec.cwd) |path| .{ .path = path } else .inherit,
        .environ_map = &environment,
        .pgid = 0,
        .stdin = if (spec.stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    // The reader owns the output pipes: `wait` would close them under it.
    const stdout_file = child.stdout.?;
    const stderr_file = child.stderr.?;
    child.stdout = null;
    child.stderr = null;
    defer stdout_file.close(io);
    defer stderr_file.close(io);

    const group = child.id.?; // the child leads its own process group (`pgid = 0`)

    // A second worker reaps the child and then kills its group, so a background process that
    // inherited the pipes cannot keep the reads below open after the child exited.
    var waiter = io.concurrent(waitAndKillGroup, .{ &child, io, group }) catch |err| {
        killGroup(group);
        child.kill(io);
        return err;
    };
    var waiter_awaited = false;
    defer if (!waiter_awaited) {
        killGroup(group);
        _ = waiter.await(io);
    };

    var stdin_feeder: Io.Group = .init;
    defer stdin_feeder.cancel(io);
    if (spec.stdin) |data| {
        const stdin_file = child.stdin.?;
        child.stdin = null;
        stdin_feeder.concurrent(io, feedAndClose, .{ io, stdin_file, data }) catch |err| {
            stdin_file.close(io);
            return err;
        };
    }

    var reader_buffer: MultiReader.Buffer(2) = undefined;
    var reader: MultiReader = undefined;
    reader.init(gpa, io, reader_buffer.toStreams(), &.{ stdout_file, stderr_file });
    defer reader.deinit();

    try readUntilEnd(&reader);

    waiter_awaited = true;
    const term = waiter.await(io) orelse return error.WaitFailed;

    const arena = operation.arena.allocator();

    return .{
        .stdout = try arena.dupe(u8, reader.reader(0).buffered()),
        .stderr = try arena.dupe(u8, reader.reader(1).buffered()),
        .exit_code = switch (term) {
            .exited => |code| code,
            else => null,
        },
        .signal = switch (term) {
            .signal => |signal| @intFromEnum(signal),
            else => null,
        },
    };
}

fn readUntilEnd(reader: *MultiReader) !void {
    while (reader.fill(64, .none)) |_| {
        const stdout_length = reader.reader(0).buffered().len;
        const stderr_length = reader.reader(1).buffered().len;
        if (stdout_length > ops.max_process_output_bytes or stderr_length > ops.max_process_output_bytes) {
            return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }

    try reader.checkAnyError();
}

fn feedAndClose(io: Io, file: File, data: []const u8) void {
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    writer.interface.writeAll(data) catch return;
    writer.interface.flush() catch return;
}

fn killGroup(group: std.process.Child.Id) void {
    _ = std.c.kill(-group, .KILL);
}

/// shortcut: the group is killed after the leader was reaped, so its id could in theory have
/// been reused; the window is microseconds. Use a `waitid(WNOWAIT)` first if that ever matters.
fn waitAndKillGroup(child: *std.process.Child, io: Io, group: std.process.Child.Id) ?std.process.Child.Term {
    const term = child.wait(io) catch return null;
    killGroup(group);

    return term;
}

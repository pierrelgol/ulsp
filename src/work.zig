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

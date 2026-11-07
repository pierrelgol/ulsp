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

    const stdout_file = child.stdout.?;
    const stderr_file = child.stderr.?;
    child.stdout = null;
    child.stderr = null;
    defer stdout_file.close(io);
    defer stderr_file.close(io);

    const group = child.id.?;

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

fn waitAndKillGroup(child: *std.process.Child, io: Io, group: std.process.Child.Id) ?std.process.Child.Term {
    const term = child.wait(io) catch return null;
    killGroup(group);

    return term;
}

test "operations over the worker cap wait and all complete" {
    var harness: TestHarness = undefined;
    harness.init();
    defer harness.deinit();

    const total_count = ops.max_workers + 8;
    for (0..total_count) |_| {
        _ = try harness.startRun(&.{ "sh", "-c", "sleep 0.2" });
    }
    for (0..total_count) |_| {
        const operation = try harness.nextCompletion();
        defer harness.table.destroyOperation(operation);

        try testing.expect(operation.result == .process);
    }

    var tokens: [ops.max_workers]u8 = undefined;
    const returned_count = try harness.table.slots.get(testing.io, &tokens, ops.max_workers);
    try testing.expectEqual(@as(usize, ops.max_workers), returned_count);
}

test "write, read, stat and list" {
    var harness: TestHarness = undefined;
    harness.init();
    defer harness.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(directory_path);
    const file_path = try std.fs.path.join(testing.allocator, &.{ directory_path, "f.txt" });
    defer testing.allocator.free(file_path);

    _ = try harness.start(.{ .write = .{ .path = file_path, .data = "hi" } });
    {
        const operation = try harness.nextCompletion();
        defer harness.table.destroyOperation(operation);

        try testing.expect(operation.result == .completed);
    }

    _ = try harness.start(.{ .read = file_path });
    {
        const operation = try harness.nextCompletion();
        defer harness.table.destroyOperation(operation);

        try testing.expectEqualStrings("hi", operation.result.bytes);
    }

    _ = try harness.start(.{ .stat = file_path });
    {
        const operation = try harness.nextCompletion();
        defer harness.table.destroyOperation(operation);

        try testing.expectEqual(@as(u64, 2), operation.result.stat.?.size);
        try testing.expectEqualStrings("file", operation.result.stat.?.kind);
    }

    _ = try harness.start(.{ .stat = "/ulsp/none" });
    {
        const operation = try harness.nextCompletion();
        defer harness.table.destroyOperation(operation);

        try testing.expect(operation.result.stat == null);
    }

    _ = try harness.start(.{ .list = directory_path });
    {
        const operation = try harness.nextCompletion();
        defer harness.table.destroyOperation(operation);

        try testing.expectEqual(@as(usize, 1), operation.result.list.len);
        try testing.expectEqualStrings("f.txt", operation.result.list[0].name);
    }
}

test "write through a symlink keeps the link" {
    var harness: TestHarness = undefined;
    harness.init();
    defer harness.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "real.txt", .data = "old" });
    try tmp.dir.symLink(testing.io, "real.txt", "link.txt", .{});

    const directory_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(directory_path);
    const link_path = try std.fs.path.join(testing.allocator, &.{ directory_path, "link.txt" });
    defer testing.allocator.free(link_path);

    _ = try harness.start(.{ .write = .{ .path = link_path, .data = "new" } });
    const operation = try harness.nextCompletion();
    defer harness.table.destroyOperation(operation);
    try testing.expect(operation.result == .completed);

    var link_buffer: [16]u8 = undefined;
    const link_length = try tmp.dir.readLink(testing.io, "link.txt", &link_buffer);
    try testing.expectEqualStrings("real.txt", link_buffer[0..link_length]);

    const real_contents = try tmp.dir.readFileAlloc(testing.io, "real.txt", testing.allocator, .limited(100));
    defer testing.allocator.free(real_contents);
    try testing.expectEqualStrings("new", real_contents);
}

test "process echoes 300 KiB of stdin" {
    var harness: TestHarness = undefined;
    harness.init();
    defer harness.deinit();

    const input = try testing.allocator.alloc(u8, 300 * 1024);
    defer testing.allocator.free(input);
    for (input, 0..) |*byte, index| {
        byte.* = @intCast('a' + index % 26);
    }

    _ = try harness.start(.{ .run = .{ .argv = &.{"cat"}, .stdin = input } });
    const operation = try harness.nextCompletion();
    defer harness.table.destroyOperation(operation);

    try testing.expectEqualSlices(u8, input, operation.result.process.stdout);
    try testing.expectEqual(@as(?u8, 0), operation.result.process.exit_code);
}

test "missing command fails" {
    var harness: TestHarness = undefined;
    harness.init();
    defer harness.deinit();

    _ = try harness.startRun(&.{"ulsp-no-such-command"});
    const operation = try harness.nextCompletion();
    defer harness.table.destroyOperation(operation);

    try testing.expect(operation.result == .failed);
    try testing.expect(std.mem.startsWith(u8, operation.result.failed, "FileNotFound: ulsp-no-such-command"));
}

test "cancel kills the child and its group" {
    var harness: TestHarness = undefined;
    harness.init();
    defer harness.deinit();

    const id = try harness.startRun(&.{ "sh", "-c", "sleep 60 & wait" });
    try testing.io.sleep(.fromMilliseconds(100), .awake);
    harness.table.cancel(id);

    try testing.expectEqual(@as(usize, 0), harness.table.operations_by_id.count());
}

test "a background child holding the pipes does not stall the operation" {
    var harness: TestHarness = undefined;
    harness.init();
    defer harness.deinit();

    _ = try harness.startRun(&.{ "sh", "-c", "sleep 60 & echo hi" });
    const operation = try harness.nextCompletion();
    defer harness.table.destroyOperation(operation);

    try testing.expectEqualStrings("hi\n", operation.result.process.stdout);
}

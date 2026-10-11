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

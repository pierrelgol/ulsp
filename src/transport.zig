const std = @import("std");
const lsp = @import("lsp");
const operations = @import("ops.zig");

const c = std.c;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ClientWriter = struct {
    pub const max_pending_bytes = 64 * 1024 * 1024;
    pub const flush_timeout_ms = 2000;
    const queue_capacity = 4096;

    const Finished = union(enum) { writer: void, timeout: void };

    gpa: Allocator,
    transport: *lsp.Transport,
    queue_storage: [queue_capacity][]u8 = undefined,
    queue: Io.Queue([]u8) = undefined,
    pending_bytes: std.atomic.Value(usize) = .init(0),
    dropped_count: usize = 0,
    finished_storage: [2]Finished = undefined,
    finished: Io.Select(Finished) = undefined,

    pub fn start(writer: *ClientWriter, io: Io) !void {
        writer.queue = .init(&writer.queue_storage);
        writer.finished = .init(io, &writer.finished_storage);
        try writer.finished.concurrent(.writer, writeUntilClosed, .{ writer, io });
    }

    pub fn push(writer: *ClientWriter, io: Io, bytes: []const u8) void {
        const message = writer.gpa.dupe(u8, bytes) catch return;
        writer.pushOwned(io, message);
    }

    pub fn pushOwned(writer: *ClientWriter, io: Io, message: []u8) void {
        const pending_after_push = writer.pending_bytes.fetchAdd(message.len, .monotonic) + message.len;
        if (pending_after_push <= ClientWriter.max_pending_bytes) {
            const queued_count = writer.queue.put(io, &.{message}, 0) catch 0;
            if (queued_count == 1) {
                return;
            }
        }

        _ = writer.pending_bytes.fetchSub(message.len, .monotonic);
        writer.dropped_count += 1;

        if (writer.dropped_count == 1 and !@import("builtin").is_test) {
            writeStderrNonBlocking("ulsp [error] client is not reading: output is being dropped\n");
        }
        writer.gpa.free(message);
    }

    pub fn finish(writer: *ClientWriter, io: Io) void {
        writer.queue.close(io);
        writer.finished.concurrent(.timeout, sleepUntilFlushDeadline, .{io}) catch {};
        _ = writer.finished.await() catch {};
        writer.finished.cancelDiscard();

        writer.discardQueued(io);
    }

    fn discardQueued(writer: *ClientWriter, io: Io) void {
        var slot: [1][]u8 = undefined;
        while ((writer.queue.get(io, &slot, 0) catch 0) == 1) {
            writer.gpa.free(slot[0]);
        }
    }

    fn sleepUntilFlushDeadline(io: Io) void {
        io.sleep(.fromMilliseconds(flush_timeout_ms), .awake) catch {};
    }

    fn writeUntilClosed(writer: *ClientWriter, io: Io) void {
        var client_alive = true;

        while (writer.queue.getOne(io)) |message| {
            defer writer.gpa.free(message);
            _ = writer.pending_bytes.fetchSub(message.len, .monotonic);

            if (client_alive) {
                writer.transport.writeJsonMessage(io, message) catch {
                    client_alive = false;
                };
            }
        } else |_| {}
    }
};

pub fn readLoop(io: std.Io, gpa: std.mem.Allocator, transport: *lsp.Transport, queue: *operations.EventQueue) void {
    while (true) {
        const bytes = transport.readJsonMessage(io, gpa) catch |err| {
            if (err == error.Canceled) {
                return;
            }
            if (err != error.EndOfStream) {
                var buffer: [128]u8 = undefined;
                const line = std.fmt.bufPrint(&buffer, "ulsp [error] cannot read a message: {s}\n", .{@errorName(err)}) catch "";
                writeStderrNonBlocking(line);
            }
            break;
        };

        queue.putOne(io, .{ .message = bytes }) catch {
            gpa.free(bytes);
            return;
        };
    }

    queue.putOne(io, .eof) catch {};
}

test "output over the cap is dropped and counted" {
    var writer: ClientWriter = .{
        .gpa = std.testing.allocator,
        .transport = undefined,
        .pending_bytes = .init(ClientWriter.max_pending_bytes - 3),
    };
    writer.queue = .init(&writer.queue_storage);

    writer.push(std.testing.io, "abc");
    try std.testing.expectEqual(@as(usize, 0), writer.dropped_count);

    writer.push(std.testing.io, "d");
    try std.testing.expectEqual(@as(usize, 1), writer.dropped_count);

    writer.discardQueued(std.testing.io);
}

pub const ProtocolStreams = struct {
    input: std.Io.File,
    output: std.Io.File,

    pub fn fromHandles(input_handle: std.Io.File.Handle, output_handle: std.Io.File.Handle) ProtocolStreams {
        return .{
            .input = .{ .handle = input_handle, .flags = .{ .nonblocking = false } },
            .output = .{ .handle = output_handle, .flags = .{ .nonblocking = false } },
        };
    }
};

pub const IsolateError = error{IsolateFailed};

const max_stderr_line_bytes = 4096;
const first_private_descriptor: c_int = 3;

pub fn isolateProtocolStreams() IsolateError!ProtocolStreams {
    const input_fd = c.fcntl(0, c.F.DUPFD_CLOEXEC, first_private_descriptor);
    if (input_fd < 0) {
        return error.IsolateFailed;
    }

    const output_fd = c.fcntl(1, c.F.DUPFD_CLOEXEC, first_private_descriptor);
    if (output_fd < 0) {
        return error.IsolateFailed;
    }

    const null_fd = c.open("/dev/null", .{ .ACCMODE = .RDWR });
    if (null_fd < 0) {
        return error.IsolateFailed;
    }
    defer _ = c.close(null_fd);

    if (c.dup2(null_fd, 0) < 0) {
        return error.IsolateFailed;
    }
    if (c.dup2(2, 1) < 0) {
        return error.IsolateFailed;
    }

    return .fromHandles(input_fd, output_fd);
}

pub fn writeStderrNonBlocking(line: []const u8) void {
    var poll_descriptor: c.pollfd = .{ .fd = 2, .events = c.POLL.OUT, .revents = 0 };
    const ready_count = c.poll(@ptrCast(&poll_descriptor), 1, 0);
    if (ready_count <= 0 or poll_descriptor.revents & c.POLL.OUT == 0) {
        return;
    }

    _ = c.write(2, line.ptr, @min(line.len, max_stderr_line_bytes));
}

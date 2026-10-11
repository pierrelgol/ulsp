//! Both directions of the client channel: the reader worker feeding the queue
//! and the writer worker behind the output.
const std = @import("std");
const lsp = @import("lsp");
const operations = @import("ops.zig");

const c = std.c;
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Only the loop thread pushes; a client slow to read never stalls the loop. Messages wait
/// in a queue, capped by `ClientWriter.max_pending_bytes` (beyond it new messages are dropped and logged).
pub const ClientWriter = struct {
    pub const max_pending_bytes = 64 * 1024 * 1024;

    /// How long `finish` lets the client take the queued output.
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

    /// Queues a copy of `bytes`. A message that cannot be copied or exceeds the cap is dropped.
    pub fn push(writer: *ClientWriter, io: Io, bytes: []const u8) void {
        const message = writer.gpa.dupe(u8, bytes) catch return;
        writer.pushOwned(io, message);
    }

    /// Queues `message`, allocated with `writer.gpa`; same drop rules as `push`.
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

        // A dropped reply leaves its request unanswered: say so, once.
        if (writer.dropped_count == 1 and !@import("builtin").is_test) {
            writeStderrNonBlocking("ulsp [error] client is not reading: output is being dropped\n");
        }
        writer.gpa.free(message);
    }

    /// Writes what is queued, then stops the worker. A client that stops reading cannot hold the
    /// exit: after `flush_timeout_ms` the blocked write is canceled and the rest is dropped.
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

        // Ends on Closed once the queue is drained, or on Canceled when `finish` gave up.
        while (writer.queue.getOne(io)) |message| {
            defer writer.gpa.free(message);
            _ = writer.pending_bytes.fetchSub(message.len, .monotonic);

            // A write failure means the client is gone (the reader reports that as eof); the rest
            // is then dropped.
            if (client_alive) {
                writer.transport.writeJsonMessage(io, message) catch {
                    client_alive = false;
                };
            }
        } else |_| {}
    }
};

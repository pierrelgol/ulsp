const std = @import("std");
const log = std.log;

const lsp = @import("lsp");
const zio = @import("zio");

const Runtime = @import("Runtime.zig");
const server = @import("server.zig");
const transport = @import("transport.zig");
const ClientWriter = transport.ClientWriter;

pub const zio_options: zio.Options = .{ .scheduling = .pinned };

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;

    // The main thread is the loop thread; tasks run on two other executors.
    const zio_runtime = zio.Runtime.init(gpa, .{ .executors = .exact(2), .enable_main_executor = false }) catch {
        log.err("ulsp: cannot start the runtime\n", .{});
        return 2;
    };
    defer zio_runtime.deinit();
    const io = zio_runtime.io();

    const streams = transport.isolateProtocolStreams() catch {
        log.err("ulsp: cannot set up the protocol streams\n", .{});
        return 2;
    };

    var read_buffer: [64 * 1024]u8 = undefined;
    var stdio_transport: lsp.Transport.Stdio = .init(&read_buffer, streams.input, streams.output);

    var client_writer: ClientWriter = .{ .gpa = gpa, .transport = &stdio_transport.transport };
    client_writer.start(io) catch {
        log.err("ulsp: cannot start the writer\n", .{});
        return 2;
    };

    const runtime = Runtime.create(
        gpa,
        io,
        init.environ_map,
        &client_writer,
        .{
            .on_message = server.onMessage,
            .reject = server.rejectUnconvertible,
        },
    ) catch |err| {
        log.err("ulsp: startup failed: {s}\n", .{@errorName(err)});
        client_writer.finish(io);
        return 2;
    };

    var reader = io.concurrent(transport.readLoop, .{ io, gpa, &stdio_transport.transport, &runtime.queue }) catch {
        log.err("ulsp: cannot start the reader\n", .{});
        client_writer.finish(io);
        runtime.destroy();
        return 2;
    };

    const exit_code = runtime.run();
    runtime.shutdown(&reader);
    client_writer.finish(io);
    runtime.destroy();

    return exit_code;
}

test {
    _ = @import("transport.zig");
    _ = @import("server.zig");
    _ = @import("lua.zig");
}

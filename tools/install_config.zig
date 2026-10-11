//! Copies files and directories into the user's ulsp config directory.
//! Usage: install_config keep|replace <destination> <source>...; `keep` leaves an existing file alone.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const env = init.environ_map;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const replace = std.mem.eql(u8, args[1], "replace");

    const base = if (env.get("XDG_CONFIG_HOME")) |dir| (if (dir.len > 0) dir else null) else null;
    const directory = base orelse if (env.get("HOME")) |home|
        try std.fs.path.join(arena, &.{ home, ".config" })
    else
        env.get("APPDATA") orelse return error.NoConfigDirectory;

    const cwd = std.Io.Dir.cwd();
    var index: usize = 2;
    while (index + 1 < args.len) : (index += 2) {
        const destination = try std.fs.path.join(arena, &.{ directory, "ulsp", args[index] });
        const source = args[index + 1];
        if (cwd.openDir(io, source, .{ .iterate = true })) |opened| {
            var source_dir = opened;
            defer source_dir.close(io);
            var walker = try source_dir.walk(arena);
            while (try walker.next(io)) |entry| {
                if (entry.kind != .file) continue;
                try copy(io, source_dir, entry.path, try std.fs.path.join(arena, &.{ destination, entry.path }), replace);
            }
        } else |_| try copy(io, cwd, source, destination, replace);
    }
}

fn copy(io: std.Io, source_dir: std.Io.Dir, source: []const u8, destination: []const u8, replace: bool) !void {
    source_dir.copyFile(source, std.Io.Dir.cwd(), destination, io, .{ .make_path = true, .replace = replace }) catch |err| switch (err) {
        error.PathAlreadyExists => return std.debug.print("ulsp: kept existing {s}\n", .{destination}),
        else => return err,
    };
}

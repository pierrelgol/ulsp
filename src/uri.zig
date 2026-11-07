const std = @import("std");
const Allocator = std.mem.Allocator;
pub const file_scheme = "file://";

pub fn toPath(gpa: Allocator, uri: []const u8) Allocator.Error!?[]u8 {
    if (!std.mem.startsWith(u8, uri, file_scheme)) {
        return null;
    }
    var rest = uri[file_scheme.len..];

    if (std.mem.startsWith(u8, rest, "localhost/")) {
        rest = rest["localhost".len..];
    }
    if (!std.mem.startsWith(u8, rest, "/")) {
        return null;
    }

    const buffer = try gpa.dupe(u8, rest);
    defer gpa.free(buffer);
    const path = std.Uri.percentDecodeInPlace(buffer);

    return try gpa.dupe(u8, path);
}

pub fn fromPath(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();

    output.writer.writeAll(file_scheme) catch return error.OutOfMemory;

    std.Uri.Component.percentEncode(&output.writer, path, isUnreserved) catch return error.OutOfMemory;

    return output.toOwnedSlice();
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~/:", byte) != null;
}

const testing = std.testing;

test "toPath decodes percent escapes and leaves malformed ones" {
    const allocator = testing.allocator;
    inline for (.{
        .{ "file:///%41", "/A" },
        .{ "file:///x%41", "/xA" },
        .{ "file:///%4", "/%4" },
        .{ "file:///%", "/%" },
        .{ "file:///%zz", "/%zz" },
        .{ "file:///a%20b", "/a b" },
    }) |case| {
        const path = (try toPath(allocator, case[0])).?;
        defer allocator.free(path);

        try testing.expectEqualStrings(case[1], path);
    }
}

test "toPath and fromPath" {
    const allocator = testing.allocator;

    const decoded = (try toPath(allocator, "file:///home/a%20b/c.lua")).?;
    defer allocator.free(decoded);
    try testing.expectEqualStrings("/home/a b/c.lua", decoded);

    try testing.expect(try toPath(allocator, "untitled:Untitled-1") == null);
    try testing.expect(try toPath(allocator, "file://host/x") == null);

    const localhost_path = (try toPath(allocator, "file://localhost/x")).?;
    defer allocator.free(localhost_path);
    try testing.expectEqualStrings("/x", localhost_path);

    const encoded = try fromPath(allocator, "/home/a b/é#.lua");
    defer allocator.free(encoded);
    try testing.expectEqualStrings("file:///home/a%20b/%C3%A9%23.lua", encoded);
}

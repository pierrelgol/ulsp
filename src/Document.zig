//! A reference-counted document. The store holds one reference while the document is open;
//! every Lua handle holds one more. `closed` is set when the store lets go of it.
//! Loop thread only.
const std = @import("std");
const offsets = @import("lsp").offsets;
const root = @import("text.zig");
const ByteRange = root.ByteRange;
const Edit = root.Edit;
const Point = root.Point;

const Document = @This();
const Allocator = std.mem.Allocator;

pub const Encoding = offsets.Encoding;
pub const Position = offsets.Position;
pub const Range = offsets.Range;

gpa: Allocator,
refs: usize = 1,
closed: bool = false,
/// An immutable copy made by `snapshot`: never in the store, never edited.
is_snapshot: bool = false,
uri: []u8,
language: []u8,
version: i64,
text: std.ArrayList(u8) = .empty,

pub fn create(gpa: Allocator, uri: []const u8, language: []const u8, version: i64, text: []const u8) Allocator.Error!*Document {
    const document = try gpa.create(Document);
    errdefer gpa.destroy(document);

    const uri_copy = try gpa.dupe(u8, uri);
    errdefer gpa.free(uri_copy);
    const language_copy = try gpa.dupe(u8, language);
    errdefer gpa.free(language_copy);

    document.* = .{ .gpa = gpa, .uri = uri_copy, .language = language_copy, .version = version };
    errdefer document.text.deinit(gpa);
    try document.text.appendSlice(gpa, text);

    return document;
}

/// A private copy of the text as it is now, owned by the caller (one reference).
pub fn snapshot(document: *const Document) Allocator.Error!*Document {
    const copy = try create(document.gpa, document.uri, document.language, document.version, document.bytes());
    copy.is_snapshot = true;

    return copy;
}

pub fn retain(document: *Document) void {
    document.refs += 1;
}

pub fn release(document: *Document) void {
    document.refs -= 1;
    if (document.refs != 0) {
        return;
    }

    const gpa = document.gpa;
    gpa.free(document.uri);
    gpa.free(document.language);
    document.text.deinit(gpa);
    gpa.destroy(document);
}

pub fn bytes(document: *const Document) []const u8 {
    return document.text.items;
}

pub fn setText(document: *Document, new_text: []const u8) Allocator.Error!void {
    document.text.clearRetainingCapacity();
    try document.text.appendSlice(document.gpa, new_text);
}

pub fn replace(document: *Document, start: usize, end: usize, new_text: []const u8) Allocator.Error!Edit {
    const start_point = document.pointAtOffset(start);
    const old_end_point = document.pointAtOffset(end);

    try document.text.replaceRange(document.gpa, start, end - start, new_text);

    var new_end_point = start_point;
    if (std.mem.lastIndexOfScalar(u8, new_text, '\n')) |last_newline| {
        new_end_point.row += @intCast(std.mem.count(u8, new_text, "\n"));
        new_end_point.column = @intCast(new_text.len - last_newline - 1);
    } else {
        new_end_point.column += @intCast(new_text.len);
    }

    return .{
        .start_byte = start,
        .old_end_byte = end,
        .new_end_byte = start + new_text.len,
        .start = start_point,
        .old_end = old_end_point,
        .new_end = new_end_point,
    };
}

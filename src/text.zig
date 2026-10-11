//! Documents as the server sees them: the open set, byte/point types, and URI handling.
//! Knows no Lua and no event loop.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Document = @import("Document.zig");
pub const uri = @import("uri.zig");

/// Row and byte column, as tree-sitter counts them (rows split on `\n` only).
pub const Point = struct {
    row: u32,
    column: u32,
};

/// A half-open span of bytes in a text.
pub const ByteRange = struct {
    start: usize,
    end: usize,
};

/// One applied text edit, in bytes and points.
pub const Edit = struct {
    start_byte: usize,
    old_end_byte: usize,
    new_end_byte: usize,
    start: Point,
    old_end: Point,
    new_end: Point,
};

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Document = @import("Document.zig");
pub const uri = @import("uri.zig");

pub const Point = struct {
    row: u32,
    column: u32,
};

pub const ByteRange = struct {
    start: usize,
    end: usize,
};

pub const Edit = struct {
    start_byte: usize,
    old_end_byte: usize,
    new_end_byte: usize,
    start: Point,
    old_end: Point,
    new_end: Point,
};

pub const DocumentStore = struct {
    gpa: Allocator,
    encoding: ?Document.Encoding = null,
    documents_by_uri: std.StringArrayHashMapUnmanaged(*Document) = .empty,

    pub fn deinit(store: *DocumentStore) void {
        for (store.documents_by_uri.values()) |document| {
            document.closed = true;
            document.release();
        }
        store.documents_by_uri.deinit(store.gpa);
    }

    pub fn effectiveEncoding(store: *const DocumentStore) Document.Encoding {
        return store.encoding orelse .@"utf-16";
    }

    pub fn find(store: *const DocumentStore, document_uri: []const u8) ?*Document {
        return store.documents_by_uri.get(document_uri);
    }

    pub fn openUris(store: *const DocumentStore) []const []const u8 {
        return store.documents_by_uri.keys();
    }

    pub fn open(store: *DocumentStore, document_uri: []const u8, language: []const u8, version: i64, text: []const u8) Allocator.Error!void {
        const document = try Document.create(store.gpa, document_uri, language, version, text);
        errdefer document.release();

        _ = store.close(document_uri);
        try store.documents_by_uri.put(store.gpa, document.uri, document);
    }

    pub fn close(store: *DocumentStore, document_uri: []const u8) bool {
        const removed = store.documents_by_uri.fetchOrderedRemove(document_uri) orelse return false;
        removed.value.closed = true;
        removed.value.release();

        return true;
    }

    test "open replaces and close removes" {
        var store: DocumentStore = .{ .gpa = std.testing.allocator };
        defer store.deinit();

        try store.open("u1", "lua", 1, "x");
        try store.open("u2", "lua", 1, "y");

        const replaced_document = store.find("u1").?;
        replaced_document.retain();
        defer replaced_document.release();

        try store.open("u1", "zig", 2, "z");
        try std.testing.expect(replaced_document.closed);
        try std.testing.expectEqualStrings("z", store.find("u1").?.bytes());
        try std.testing.expectEqualStrings("u2", store.openUris()[0]);

        try std.testing.expect(store.close("u2"));
        try std.testing.expect(!store.close("u2"));
    }
};

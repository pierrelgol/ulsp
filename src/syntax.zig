const std = @import("std");
const ts = @import("zts");
const Allocator = std.mem.Allocator;
const DynLib = std.DynLib;
const Document = @import("text.zig").Document;
const Edit = @import("text.zig").Edit;

pub const Language = struct {
    name: []u8,
    path: []u8,
    tree_sitter_language: *const ts.Language,
    library: DynLib,
};

pub const SharedTree = struct {
    gpa: Allocator,
    refs: usize = 1,
    tree: *ts.Tree,
    text: []u8,
    language: *Language,
    version: i64 = 0,
    base: ?*ts.Tree = null,
    base_invalid: bool = false,

    pub fn retain(shared_tree: *SharedTree) void {
        shared_tree.refs += 1;
    }

    pub fn release(shared_tree: *SharedTree) void {
        shared_tree.refs -= 1;
        if (shared_tree.refs != 0) {
            return;
        }

        if (shared_tree.base) |base_tree| {
            base_tree.destroy();
        }
        shared_tree.tree.destroy();
        shared_tree.gpa.free(shared_tree.text);
        shared_tree.gpa.destroy(shared_tree);
    }
};

pub const Trees = struct {
    pub const LoadError = error{ CannotOpen, SymbolNotFound, IncompatibleAbi, OutOfMemory };
    pub const ParseError = error{ OutOfMemory, ParseFailed };

    const LanguageEntryPoint = *const fn () callconv(.c) *const anyopaque;

    gpa: Allocator,
    languages_by_name: std.StringHashMapUnmanaged(*Language) = .empty,
    cache: std.StringHashMapUnmanaged(*SharedTree) = .empty,

    pub fn deinit(trees: *Trees) void {
        var cache_iterator = trees.cache.iterator();
        while (cache_iterator.next()) |entry| {
            entry.value_ptr.*.release();
            trees.gpa.free(entry.key_ptr.*);
        }
        trees.cache.deinit(trees.gpa);

        var language_iterator = trees.languages_by_name.valueIterator();
        while (language_iterator.next()) |language| {
            trees.gpa.free(language.*.name);
            trees.gpa.free(language.*.path);
            trees.gpa.destroy(language.*);
        }
        trees.languages_by_name.deinit(trees.gpa);
    }

    pub fn findLanguage(trees: *const Trees, name: []const u8) ?*Language {
        return trees.languages_by_name.get(name);
    }

    pub fn loadLanguage(trees: *Trees, name: []const u8, path: []const u8) LoadError!*Language {
        if (trees.findLanguage(name)) |loaded_language| {
            return loaded_language;
        }

        var library = DynLib.open(path) catch return error.CannotOpen;
        errdefer library.close();

        const symbol_name = try std.fmt.allocPrintSentinel(trees.gpa, "tree_sitter_{s}", .{name}, 0);
        defer trees.gpa.free(symbol_name);
        const entry_point = library.lookup(LanguageEntryPoint, symbol_name) orelse return error.SymbolNotFound;

        const tree_sitter_language = ts.Language.fromRaw(entry_point());
        const abi_version = tree_sitter_language.abiVersion();
        if (abi_version < ts.MIN_COMPATIBLE_LANGUAGE_VERSION or abi_version > ts.LANGUAGE_VERSION) {
            return error.IncompatibleAbi;
        }

        const language = try trees.gpa.create(Language);
        errdefer trees.gpa.destroy(language);
        language.* = .{
            .name = try trees.gpa.dupe(u8, name),
            .path = undefined,
            .tree_sitter_language = tree_sitter_language,
            .library = library,
        };
        errdefer trees.gpa.free(language.name);
        language.path = try trees.gpa.dupe(u8, path);
        errdefer trees.gpa.free(language.path);

        try trees.languages_by_name.put(trees.gpa, language.name, language);

        return language;
    }

    pub fn parse(trees: *Trees, language: *Language, text: []const u8, previous_tree: ?*const ts.Tree) ParseError!*SharedTree {
        const text_copy = try trees.gpa.dupe(u8, text);
        errdefer trees.gpa.free(text_copy);

        const shared_tree = try trees.gpa.create(SharedTree);
        errdefer trees.gpa.destroy(shared_tree);

        const parser = ts.Parser.create();
        defer parser.destroy();
        parser.setLanguage(language.tree_sitter_language) catch return error.ParseFailed;
        const tree = parser.parseString(text_copy, previous_tree) orelse return error.ParseFailed;

        shared_tree.* = .{ .gpa = trees.gpa, .tree = tree, .text = text_copy, .language = language };

        return shared_tree;
    }

    pub fn treeForDocument(trees: *Trees, document: *const Document, language: *Language) ParseError!*SharedTree {
        const key = try std.fmt.allocPrint(trees.gpa, "{s}\x00{s}", .{ document.uri, language.name });
        defer trees.gpa.free(key);

        const cached_tree = trees.cache.get(key);
        if (cached_tree) |cached| {
            if (cached.version == document.version) {
                cached.retain();
                return cached;
            }
        }

        if (document.is_snapshot) {
            const snapshot_tree = try trees.parse(language, document.bytes(), null);
            snapshot_tree.version = document.version;
            return snapshot_tree;
        }

        var previous_tree: ?*const ts.Tree = null;
        if (cached_tree) |cached| {
            if (!cached.base_invalid) {
                previous_tree = cached.base;
            }
        }

        const fresh_tree = try trees.parse(language, document.bytes(), previous_tree);
        errdefer fresh_tree.release();
        fresh_tree.version = document.version;

        try trees.putInCache(key, fresh_tree);
        fresh_tree.retain();

        return fresh_tree;
    }

    pub fn recordEdit(trees: *Trees, uri: []const u8, edit: Edit) void {
        const input_edit = inputEditFromEdit(edit);

        var iterator = trees.cache.iterator();
        while (iterator.next()) |entry| {
            if (!keyBelongsToUri(entry.key_ptr.*, uri)) {
                continue;
            }

            const shared_tree = entry.value_ptr.*;
            if (shared_tree.base_invalid) {
                continue;
            }
            if (shared_tree.base == null) {
                shared_tree.base = shared_tree.tree.dupe();
            }
            shared_tree.base.?.edit(input_edit);
        }
    }

    pub fn invalidateBases(trees: *Trees, uri: []const u8) void {
        var iterator = trees.cache.iterator();
        while (iterator.next()) |entry| {
            if (keyBelongsToUri(entry.key_ptr.*, uri)) {
                entry.value_ptr.*.base_invalid = true;
            }
        }
    }

    pub fn dropDocument(trees: *Trees, uri: []const u8) void {
        var iterator = trees.cache.iterator();
        while (iterator.next()) |entry| {
            if (!keyBelongsToUri(entry.key_ptr.*, uri)) {
                continue;
            }

            const key = entry.key_ptr.*;
            const shared_tree = entry.value_ptr.*;
            trees.cache.removeByPtr(entry.key_ptr);
            shared_tree.release();
            trees.gpa.free(key);
        }
    }

    fn putInCache(trees: *Trees, key: []const u8, shared_tree: *SharedTree) Allocator.Error!void {
        if (trees.cache.getPtr(key)) |slot| {
            slot.*.release();
            slot.* = shared_tree;
            return;
        }

        const owned_key = try trees.gpa.dupe(u8, key);
        errdefer trees.gpa.free(owned_key);
        try trees.cache.put(trees.gpa, owned_key, shared_tree);
    }

    fn keyBelongsToUri(key: []const u8, uri: []const u8) bool {
        return key.len > uri.len and key[uri.len] == 0 and std.mem.eql(u8, key[0..uri.len], uri);
    }

    fn inputEditFromEdit(edit: Edit) ts.InputEdit {
        return .{
            .start_byte = @intCast(edit.start_byte),
            .old_end_byte = @intCast(edit.old_end_byte),
            .new_end_byte = @intCast(edit.new_end_byte),
            .start_point = .{ .row = edit.start.row, .column = edit.start.column },
            .old_end_point = .{ .row = edit.old_end.row, .column = edit.old_end.column },
            .new_end_point = .{ .row = edit.new_end.row, .column = edit.new_end.column },
        };
    }

    test "cache keys match only their own uri" {
        try std.testing.expect(keyBelongsToUri("file:///a\x00lua", "file:///a"));
        try std.testing.expect(!keyBelongsToUri("file:///ab\x00lua", "file:///a"));
        try std.testing.expect(!keyBelongsToUri("file:///a", "file:///a"));
    }
};

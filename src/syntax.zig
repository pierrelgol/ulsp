//! Tree-sitter host: grammars loaded at run time and the parse-tree cache.
//! Knows no Lua.
const std = @import("std");
const ts = @import("zts");

const Allocator = std.mem.Allocator;
const DynLib = std.DynLib;
const Document = @import("text.zig").Document;
const Edit = @import("text.zig").Edit;

/// A grammar. Never freed before exit, and its library is never unloaded.
pub const Language = struct {
    name: []u8,
    path: []u8,
    tree_sitter_language: *const ts.Language,
    library: DynLib,
};

/// A parsed tree with the text it was parsed from, shared by the cache, tree handles and nodes.
pub const SharedTree = struct {
    gpa: Allocator,
    refs: usize = 1,
    tree: *ts.Tree,
    text: []u8,
    language: *Language,
    version: i64 = 0,
    /// Cache entries only: a private copy of `tree` with every edit since `version` applied,
    /// the old tree for the next parse. `tree` itself stays untouched (Lua may hold nodes).
    base: ?*ts.Tree = null,
    /// A whole-text change happened since `version`: `base` cannot be trusted.
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

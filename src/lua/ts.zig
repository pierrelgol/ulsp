//! Lua's view of tree-sitter: the userdata boxes (language, tree, node, query) and their methods.

const convert = @import("convert.zig");
const document_calls = @import("document.zig").document_calls;
const std = @import("std");
const zlua = @import("zlua");
const ts = @import("zts");
const SharedTree = @import("../syntax.zig").SharedTree;
const Language = @import("../syntax.zig").Language;
const Runtime = @import("../Runtime.zig");
const offsets = @import("lsp").offsets;
const Document = @import("../text.zig").Document;
const Trees = @import("../syntax.zig").Trees;

const Lua = zlua.Lua;
const raise = convert.raise;
const positions = convert.positions;
const wrap = zlua.wrap;

/// The userdata behind a tree-sitter node. Holds one reference to the tree that owns the node.
pub const NodeBox = struct {
    pub const metatable_name = "ulsp.ts.node";

    node: ts.Node,
    shared_tree: *SharedTree,

    /// Takes one new reference on `shared_tree`.
    pub fn push(lua: *Lua, shared_tree: *SharedTree, node: ts.Node) void {
        const box = lua.newUserdata(NodeBox, 0);
        shared_tree.retain();
        box.* = .{ .node = node, .shared_tree = shared_tree };
        lua.setMetatableRegistry(metatable_name);
    }

    pub fn pushOptional(lua: *Lua, shared_tree: *SharedTree, maybe_node: ?ts.Node) void {
        if (maybe_node) |node| {
            push(lua, shared_tree, node);
        } else {
            lua.pushNil();
        }
    }

    pub fn argument(lua: *Lua, index: i32) *NodeBox {
        return lua.checkUserdata(NodeBox, index, metatable_name);
    }

    pub fn release(lua: *Lua) i32 {
        const box = lua.toUserdata(NodeBox, 1) catch return 0;
        box.shared_tree.release();

        return 0;
    }

    pub fn equal(lua: *Lua) i32 {
        const left = lua.toUserdata(NodeBox, 1) catch return 0;
        const right = lua.toUserdata(NodeBox, 2) catch return 0;
        lua.pushBoolean(left.shared_tree == right.shared_tree and left.node.eql(right.node));

        return 1;
    }

    /// The node's byte bounds, clamped to the text so a bad tree cannot slice out of range.
    pub fn byteBounds(box: *const NodeBox) struct { start: usize, end: usize } {
        const text_length = box.shared_tree.text.len;
        const start = @min(box.node.startByte(), text_length);
        const end = @max(start, @min(box.node.endByte(), text_length));

        return .{ .start = start, .end = end };
    }

    pub fn bytes(box: *const NodeBox) []const u8 {
        const bounds = box.byteBounds();

        return box.shared_tree.text[bounds.start..bounds.end];
    }
};

/// The userdata behind a tree handle. Holds one reference to the shared tree.
pub const TreeBox = struct {
    pub const metatable_name = "ulsp.ts.tree";

    shared_tree: *SharedTree,

    /// Takes one new reference on `shared_tree`.
    pub fn push(lua: *Lua, shared_tree: *SharedTree) void {
        const box = lua.newUserdata(TreeBox, 0);
        shared_tree.retain();
        box.* = .{ .shared_tree = shared_tree };
        lua.setMetatableRegistry(metatable_name);
    }

    pub fn release(lua: *Lua) i32 {
        const box = lua.toUserdata(TreeBox, 1) catch return 0;
        box.shared_tree.release();

        return 0;
    }

    pub fn root(lua: *Lua) i32 {
        const box = lua.checkUserdata(TreeBox, 1, metatable_name);
        NodeBox.push(lua, box.shared_tree, box.shared_tree.tree.rootNode());

        return 1;
    }

    pub fn text(lua: *Lua) i32 {
        const box = lua.checkUserdata(TreeBox, 1, metatable_name);
        _ = lua.pushString(box.shared_tree.text);

        return 1;
    }
};

/// The userdata behind a tree-sitter language value. Languages live as long as the process.
pub const LanguageBox = struct {
    pub const metatable_name = "ulsp.ts.language";

    language: *Language,

    pub fn push(lua: *Lua, language: *Language) void {
        const box = lua.newUserdata(LanguageBox, 0);
        box.* = .{ .language = language };
        lua.setMetatableRegistry(metatable_name);
    }

    /// A language value or the name of a loaded language.
    pub fn argument(lua: *Lua, runtime: *Runtime, index: i32) *Language {
        if (lua.typeOf(index) == .string) {
            const name = lua.toString(index) catch unreachable;

            return runtime.trees.findLanguage(name) orelse raise.formatted(lua, "ulsp: language \"{s}\" is not loaded", .{name});
        }

        return lua.checkUserdata(LanguageBox, index, metatable_name).language;
    }

    pub fn equal(lua: *Lua) i32 {
        const left = lua.toUserdata(LanguageBox, 1) catch return 0;
        const right = lua.toUserdata(LanguageBox, 2) catch return 0;
        lua.pushBoolean(left.language == right.language);

        return 1;
    }
};

/// The userdata behind a compiled tree-sitter query.
pub const QueryBox = struct {
    pub const metatable_name = "ulsp.ts.query";

    query: *ts.Query,
    language: *Language,

    pub fn push(lua: *Lua, query: *ts.Query, language: *Language) void {
        const box = lua.newUserdata(QueryBox, 0);
        box.* = .{ .query = query, .language = language };
        lua.setMetatableRegistry(metatable_name);
    }

    pub fn argument(lua: *Lua, index: i32) *QueryBox {
        return lua.checkUserdata(QueryBox, index, metatable_name);
    }

    pub fn release(lua: *Lua) i32 {
        const box = lua.toUserdata(QueryBox, 1) catch return 0;
        box.query.destroy();

        return 0;
    }

    pub fn captureName(box: *const QueryBox, capture_id: u32) []const u8 {
        return box.query.captureNameForId(capture_id) orelse "";
    }
};

/// A query runs on the loop thread, so it gets a time budget; generous enough for any real query.
pub const QueryBudget = struct {
    const budget_ms = 2000;
    io: std.Io,
    deadline_ns: i96,
    hit: bool = false,

    pub fn init(io: std.Io) QueryBudget {
        return .{
            .io = io,
            .deadline_ns = std.Io.Clock.awake.now(io).nanoseconds + budget_ms * std.time.ns_per_ms,
        };
    }

    /// Starts `cursor` on `node`; the budget must outlive the cursor.
    pub fn execute(budget: *QueryBudget, cursor: *ts.QueryCursor, query: *ts.Query, node: ts.Node) void {
        cursor.execWithOptions(query, node, &.{ .payload = budget, .progress_callback = checkDeadline });
    }

    fn checkDeadline(state: ts.QueryCursor.State) callconv(.c) bool {
        const budget: *QueryBudget = @ptrCast(@alignCast(state.payload.?));
        if (std.Io.Clock.awake.now(budget.io).nanoseconds < budget.deadline_ns) {
            return false;
        }

        budget.hit = true;

        return true;
    }
};

/// The methods of tree-sitter node handles The generated functions take the
/// tree-sitter method name, which must stay as the library spells it.
pub const node_calls = struct {
    pub const methods = .{
        .{ "type", nodeType },
        .{ "is_named", flagMethod("isNamed") },
        .{ "is_missing", flagMethod("isMissing") },
        .{ "is_error", flagMethod("isError") },
        .{ "has_error", flagMethod("hasError") },
        .{ "text", nodeText },
        .{ "range", nodeRange },
        .{ "byte_range", nodeByteRange },
        .{ "start_point", pointMethod("startPoint") },
        .{ "end_point", pointMethod("endPoint") },
        .{ "child_count", countMethod("childCount") },
        .{ "named_child_count", countMethod("namedChildCount") },
        .{ "child", childAtMethod("child") },
        .{ "named_child", childAtMethod("namedChild") },
        .{ "children", childrenMethod("child", "childCount") },
        .{ "named_children", childrenMethod("namedChild", "namedChildCount") },
        .{ "field", nodeField },
        .{ "parent", relativeMethod("parent") },
        .{ "next_sibling", relativeMethod("nextSibling") },
        .{ "prev_sibling", relativeMethod("prevSibling") },
        .{ "next_named_sibling", relativeMethod("nextNamedSibling") },
        .{ "prev_named_sibling", relativeMethod("prevNamedSibling") },
        .{ "descendant_for_range", descendantMethod("descendantForByteRange") },
        .{ "named_descendant_for_range", descendantMethod("namedDescendantForByteRange") },
        .{ "sexp", nodeSexp },
    };

    /// Character offset of `byte` on its line, in `encoding`; `column` is the byte column from
    /// tree-sitter.
    pub fn characterOnLine(text: []const u8, encoding: Document.Encoding, byte: u32, column: u32) u32 {
        const line_start = byte - @min(column, byte);

        return @intCast(offsets.countCodeUnits(text[line_start..byte], encoding));
    }

    fn unsignedArgument(lua: *Lua, index: i32) u32 {
        return @intCast(std.math.clamp(lua.checkInteger(index), 0, std.math.maxInt(u32)));
    }

    fn nodeType(lua: *Lua) i32 {
        _ = lua.pushString(NodeBox.argument(lua, 1).node.kind());

        return 1;
    }

    fn flagMethod(comptime method: []const u8) fn (*Lua) i32 {
        return struct {
            fn call(lua: *Lua) i32 {
                lua.pushBoolean(@field(ts.Node, method)(NodeBox.argument(lua, 1).node));

                return 1;
            }
        }.call;
    }

    fn nodeText(lua: *Lua) i32 {
        _ = lua.pushString(NodeBox.argument(lua, 1).bytes());

        return 1;
    }

    fn nodeRange(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const box = NodeBox.argument(lua, 1);
        const encoding = runtime.documents.effectiveEncoding();
        const text = box.shared_tree.text;
        const bounds = box.byteBounds();
        const start_point = box.node.startPoint();
        const end_point = box.node.endPoint();

        positions.pushRange(lua, .{
            .start = .{
                .line = start_point.row,
                .character = characterOnLine(text, encoding, @intCast(bounds.start), start_point.column),
            },
            .end = .{
                .line = end_point.row,
                .character = characterOnLine(text, encoding, @intCast(bounds.end), end_point.column),
            },
        });

        return 1;
    }

    fn nodeByteRange(lua: *Lua) i32 {
        const box = NodeBox.argument(lua, 1);
        lua.pushInteger(box.node.startByte());
        lua.pushInteger(box.node.endByte());

        return 2;
    }

    fn pointMethod(comptime method: []const u8) fn (*Lua) i32 {
        return struct {
            fn call(lua: *Lua) i32 {
                const point = @field(ts.Node, method)(NodeBox.argument(lua, 1).node);

                lua.createTable(0, 2);
                lua.pushInteger(point.row);
                lua.setField(-2, "row");
                lua.pushInteger(point.column);
                lua.setField(-2, "column");

                return 1;
            }
        }.call;
    }

    fn countMethod(comptime method: []const u8) fn (*Lua) i32 {
        return struct {
            fn call(lua: *Lua) i32 {
                lua.pushInteger(@field(ts.Node, method)(NodeBox.argument(lua, 1).node));

                return 1;
            }
        }.call;
    }

    /// `node:child(i)` counts from 1.
    fn childAtMethod(comptime method: []const u8) fn (*Lua) i32 {
        return struct {
            fn call(lua: *Lua) i32 {
                const box = NodeBox.argument(lua, 1);
                const position = lua.checkInteger(2);

                var child: ?ts.Node = null;
                if (position >= 1 and position <= std.math.maxInt(u32)) {
                    child = @field(ts.Node, method)(box.node, @intCast(position - 1));
                }
                NodeBox.pushOptional(lua, box.shared_tree, child);

                return 1;
            }
        }.call;
    }

    fn childrenMethod(comptime method: []const u8, comptime count_method: []const u8) fn (*Lua) i32 {
        return struct {
            fn call(lua: *Lua) i32 {
                const box = NodeBox.argument(lua, 1);
                const child_count = @field(ts.Node, count_method)(box.node);

                lua.createTable(@intCast(child_count), 0);

                // shortcut: child(i) is O(i); use a tree cursor if very wide nodes show up.
                var child_index: u32 = 0;
                while (child_index < child_count) : (child_index += 1) {
                    const child = @field(ts.Node, method)(box.node, child_index) orelse break;
                    NodeBox.push(lua, box.shared_tree, child);
                    lua.setIndex(-2, @intCast(child_index + 1));
                }

                return 1;
            }
        }.call;
    }

    fn nodeField(lua: *Lua) i32 {
        const box = NodeBox.argument(lua, 1);
        const name = lua.checkString(2);

        NodeBox.pushOptional(lua, box.shared_tree, box.node.childByFieldName(name));

        return 1;
    }

    fn relativeMethod(comptime method: []const u8) fn (*Lua) i32 {
        return struct {
            fn call(lua: *Lua) i32 {
                const box = NodeBox.argument(lua, 1);
                NodeBox.pushOptional(lua, box.shared_tree, @field(ts.Node, method)(box.node));

                return 1;
            }
        }.call;
    }

    fn descendantMethod(comptime method: []const u8) fn (*Lua) i32 {
        return struct {
            fn call(lua: *Lua) i32 {
                const box = NodeBox.argument(lua, 1);
                const start_byte = unsignedArgument(lua, 2);
                const end_byte = unsignedArgument(lua, 3);

                NodeBox.pushOptional(lua, box.shared_tree, @field(ts.Node, method)(box.node, start_byte, end_byte));

                return 1;
            }
        }.call;
    }

    fn nodeSexp(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const box = NodeBox.argument(lua, 1);

        const sexp = box.node.toSexp(runtime.gpa) catch raise.text(lua, "out of memory");
        defer runtime.gpa.free(sexp);

        _ = lua.pushString(sexp);

        return 1;
    }
};

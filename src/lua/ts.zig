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

pub const NodeBox = struct {
    pub const metatable_name = "ulsp.ts.node";

    node: ts.Node,
    shared_tree: *SharedTree,

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

pub const TreeBox = struct {
    pub const metatable_name = "ulsp.ts.tree";

    shared_tree: *SharedTree,

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

pub const LanguageBox = struct {
    pub const metatable_name = "ulsp.ts.language";

    language: *Language,

    pub fn push(lua: *Lua, language: *Language) void {
        const box = lua.newUserdata(LanguageBox, 0);
        box.* = .{ .language = language };
        lua.setMetatableRegistry(metatable_name);
    }

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

pub const query_calls = struct {
    pub const methods = .{
        .{ "captures", captures },
        .{ "matches", matches },
        .{ "capture_names", captureNames },
    };

    pub fn create(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const language = LanguageBox.argument(lua, runtime, 1);
        const source = lua.checkString(2);

        var error_offset: u32 = 0;
        const query = ts.Query.create(language.tree_sitter_language, source, &error_offset) catch |err| {
            raise.formatted(lua, "query error at byte {d}: {s}", .{ error_offset, errorKind(err) });
        };
        QueryBox.push(lua, query, language);

        return 1;
    }

    fn errorKind(err: ts.Query.Error) []const u8 {
        return switch (err) {
            error.InvalidSyntax => "syntax",
            error.InvalidNodeType => "node_type",
            error.InvalidField => "field",
            error.InvalidCapture => "capture",
            error.InvalidStructure => "structure",
            error.InvalidLanguage => "language",
        };
    }

    const Arguments = struct { query_box: *QueryBox, node_box: *NodeBox };

    fn readArguments(lua: *Lua) Arguments {
        const query_box = QueryBox.argument(lua, 1);
        const node_box = NodeBox.argument(lua, 2);
        if (node_box.shared_tree.language != query_box.language) {
            raise.text(lua, "ulsp: query and node use different languages");
        }

        return .{ .query_box = query_box, .node_box = node_box };
    }

    fn raiseTimedOut(lua: *Lua, cursor: *ts.QueryCursor) noreturn {
        cursor.destroy();
        raise.text(lua, "ulsp: query timed out");
    }

    fn captures(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const arguments = readArguments(lua);
        const query_box = arguments.query_box;
        const node_box = arguments.node_box;

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        var budget: QueryBudget = .init(runtime.io);
        budget.execute(cursor, query_box.query, node_box.node);

        lua.createTable(0, 0);
        var result_count: i64 = 0;
        while (cursor.nextCapture()) |next| {
            const capture_index, const match = next;
            const capture = match.captures[capture_index];
            result_count += 1;

            lua.createTable(2, 0);
            _ = lua.pushString(query_box.captureName(capture.index));
            lua.setIndex(-2, 1);
            NodeBox.push(lua, node_box.shared_tree, capture.node);
            lua.setIndex(-2, 2);
            lua.setIndex(-2, @intCast(result_count));
        }

        if (budget.hit) {
            raiseTimedOut(lua, cursor);
        }

        return 1;
    }

    fn matches(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const arguments = readArguments(lua);
        const query_box = arguments.query_box;
        const node_box = arguments.node_box;

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        var budget: QueryBudget = .init(runtime.io);
        budget.execute(cursor, query_box.query, node_box.node);

        lua.createTable(0, 0);
        var result_count: i64 = 0;
        while (cursor.nextMatch()) |match| {
            result_count += 1;

            lua.createTable(0, @intCast(match.captures.len));
            for (match.captures) |capture| {
                pushCaptureIfNew(lua, query_box, node_box, capture);
            }
            lua.setIndex(-2, @intCast(result_count));
        }

        if (budget.hit) {
            raiseTimedOut(lua, cursor);
        }

        return 1;
    }

    fn pushCaptureIfNew(lua: *Lua, query_box: *const QueryBox, node_box: *const NodeBox, capture: ts.Query.Capture) void {
        const name = query_box.captureName(capture.index);

        _ = lua.pushString(name);
        const already_present = lua.getTable(-2) != .nil;
        lua.pop(1);
        if (already_present) {
            return;
        }

        _ = lua.pushString(name);
        NodeBox.push(lua, node_box.shared_tree, capture.node);
        lua.setTable(-3);
    }

    fn captureNames(lua: *Lua) i32 {
        const query_box = QueryBox.argument(lua, 1);
        const capture_count = query_box.query.captureCount();

        lua.createTable(@intCast(capture_count), 0);
        var capture_id: u32 = 0;
        while (capture_id < capture_count) : (capture_id += 1) {
            _ = lua.pushString(query_box.captureName(capture_id));
            lua.setIndex(-2, @intCast(capture_id + 1));
        }

        return 1;
    }
};

pub const ts_calls = struct {
    pub fn register(lua: *Lua) void {
        inline for (.{
            .{ "ts_load", load },
            .{ "ts_language", language },
            .{ "ts_parse", parse },
            .{ "ts_tree", tree },
            .{ "ts_query", query_calls.create },
        }) |entry| {
            lua.pushFunction(wrap(entry[1]));
            lua.setField(-2, entry[0]);
        }

        registerMetatable(lua, LanguageBox.metatable_name, .{}, null, LanguageBox.equal);
        registerMetatable(lua, TreeBox.metatable_name, .{
            .{ "root", TreeBox.root },
            .{ "text", TreeBox.text },
        }, TreeBox.release, null);
        registerMetatable(lua, NodeBox.metatable_name, node_calls.methods, NodeBox.release, NodeBox.equal);
        registerMetatable(lua, QueryBox.metatable_name, query_calls.methods, QueryBox.release, null);
    }

    fn registerMetatable(lua: *Lua, name: [:0]const u8, comptime methods: anytype, comptime gc: anytype, comptime equal: anytype) void {
        lua.newMetatable(name) catch unreachable;

        lua.createTable(0, methods.len);
        inline for (methods) |method| {
            lua.pushFunction(wrap(method[1]));
            lua.setField(-2, method[0]);
        }
        lua.setField(-2, "__index");

        if (@TypeOf(gc) != @TypeOf(null)) {
            lua.pushFunction(wrap(gc));
            lua.setField(-2, "__gc");
        }
        if (@TypeOf(equal) != @TypeOf(null)) {
            lua.pushFunction(wrap(equal));
            lua.setField(-2, "__eq");
        }

        lua.pop(1);
    }

    fn load(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const name = lua.checkString(1);
        const path = lua.checkString(2);

        const loaded_language = runtime.trees.loadLanguage(name, path) catch |err| switch (err) {
            error.CannotOpen => raise.formatted(lua, "ulsp: cannot open {s}", .{path}),
            error.SymbolNotFound => raise.formatted(lua, "ulsp: symbol tree_sitter_{s} not found in {s}", .{ name, path }),
            error.IncompatibleAbi => raise.formatted(lua, "ulsp: language \"{s}\" has an incompatible ABI version", .{name}),
            error.OutOfMemory => raise.text(lua, "out of memory"),
        };

        if (!std.mem.eql(u8, loaded_language.path, path)) {
            var buffer: [512]u8 = undefined;
            const warning = std.fmt.bufPrint(&buffer, "ts.load: \"{s}\" is already loaded from {s}; ignoring {s}", .{ name, loaded_language.path, path }) catch &buffer;
            runtime.log(2, warning);
        }

        LanguageBox.push(lua, loaded_language);

        return 1;
    }

    fn language(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const name = lua.checkString(1);

        if (runtime.trees.findLanguage(name)) |found_language| {
            LanguageBox.push(lua, found_language);
        } else {
            lua.pushNil();
        }

        return 1;
    }

    fn raiseParseError(lua: *Lua, err: Trees.ParseError) noreturn {
        switch (err) {
            error.OutOfMemory => raise.text(lua, "out of memory"),
            error.ParseFailed => raise.text(lua, "ulsp: parse failed"),
        }
    }

    fn parse(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const parse_language = LanguageBox.argument(lua, runtime, 1);
        const text = lua.checkString(2);

        const shared_tree = runtime.trees.parse(parse_language, text, null) catch |err| raiseParseError(lua, err);
        TreeBox.push(lua, shared_tree);
        shared_tree.release();
        runtime.noteNativeBytes(text.len);

        return 1;
    }

    fn tree(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const tree_language = LanguageBox.argument(lua, runtime, 2);

        const document = if (lua.typeOf(1) == .userdata)
            document_calls.documentArgument(lua, runtime, 1)
        else
            runtime.documents.find(lua.checkString(1)) orelse {
                lua.pushNil();
                return 1;
            };

        const shared_tree = runtime.trees.treeForDocument(document, tree_language) catch |err| raiseParseError(lua, err);
        TreeBox.push(lua, shared_tree);
        shared_tree.release();

        if (document.is_snapshot) {
            runtime.noteNativeBytes(document.bytes().len * 4);
        }

        return 1;
    }
};

test "character counts utf-16 units on the line" {
    const text = "a\u{1F600}b";
    try std.testing.expectEqual(@as(u32, 3), node_calls.characterOnLine(text, .@"utf-16", 5, 5));
    try std.testing.expectEqual(@as(u32, 5), node_calls.characterOnLine(text, .@"utf-8", 5, 5));
    try std.testing.expectEqual(@as(u32, 1), node_calls.characterOnLine("ab\ncd", .@"utf-16", 4, 1));
}

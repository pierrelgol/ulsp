//! Lua's view of documents: the handle userdata and the `ulsp.documents` / document methods.

const convert = @import("convert.zig");
const zlua = @import("zlua");
const Document = @import("../text.zig").Document;
const Runtime = @import("../Runtime.zig");
const std = @import("std");
const ByteRange = @import("../text.zig").ByteRange;

const Lua = zlua.Lua;
const raise = convert.raise;
const positions = convert.positions;
const wrap = zlua.wrap;

/// The userdata behind a document handle. Holds one reference to the document.
pub const DocumentHandle = struct {
    document: *Document,

    /// Takes a new reference on `document`.
    pub fn push(lua: *Lua, runtime: *Runtime, document: *Document) void {
        document.retain();

        const handle = lua.newUserdata(DocumentHandle, 0);
        handle.* = .{ .document = document };
        _ = lua.getIndexRaw(zlua.registry_index, runtime.document_metatable_ref);
        lua.setMetatable(-2);
    }

    pub fn release(lua: *Lua) i32 {
        const handle = lua.toUserdata(DocumentHandle, 1) catch return 0;
        handle.document.release();

        return 0;
    }
};

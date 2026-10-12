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

pub const DocumentHandle = struct {
    document: *Document,

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

pub const document_calls = struct {
    pub fn get(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const uri = lua.checkString(1);

        const document = runtime.documents.find(uri) orelse {
            lua.pushNil();
            return 1;
        };
        DocumentHandle.push(lua, runtime, document);

        return 1;
    }

    pub fn list(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const uris = runtime.documents.openUris();

        lua.createTable(@intCast(uris.len), 0);
        for (uris, 1..) |uri, position| {
            _ = lua.pushString(uri);
            lua.setIndex(-2, @intCast(position));
        }

        return 1;
    }

    pub fn pushMetatable(lua: *Lua) void {
        lua.createTable(0, 3);

        lua.createTable(0, 10);
        inline for (.{
            .{ "uri", documentUri },
            .{ "version", documentVersion },
            .{ "language", documentLanguage },
            .{ "text", documentText },
            .{ "snapshot", documentSnapshot },
            .{ "line_count", documentLineCount },
            .{ "line", documentLine },
            .{ "offset", documentOffset },
            .{ "position", documentPosition },
            .{ "range", documentRange },
        }) |entry| {
            lua.pushFunction(wrap(entry[1]));
            lua.setField(-2, entry[0]);
        }
        lua.setField(-2, "__index");

        lua.pushFunction(wrap(DocumentHandle.release));
        lua.setField(-2, "__gc");
    }

    pub fn documentArgument(lua: *Lua, runtime: *Runtime, index: i32) *Document {
        if (lua.typeOf(index) != .userdata) {
            raise.text(lua, "ulsp: expected a document");
        }

        const handle = lua.toUserdata(DocumentHandle, index) catch raise.text(lua, "ulsp: expected a document");
        lua.getMetatable(index) catch raise.text(lua, "ulsp: expected a document");
        _ = lua.getIndexRaw(zlua.registry_index, runtime.document_metatable_ref);
        const is_document_metatable = lua.equalRaw(-1, -2);
        lua.pop(2);

        if (!is_document_metatable) {
            raise.text(lua, "ulsp: expected a document");
        }
        if (handle.document.closed) {
            raise.text(lua, "ulsp: document closed");
        }

        return handle.document;
    }

    fn receiver(lua: *Lua, runtime: *Runtime) *Document {
        return documentArgument(lua, runtime, 1);
    }

    fn documentUri(lua: *Lua) i32 {
        const document = receiver(lua, Runtime.of(lua));
        _ = lua.pushString(document.uri);

        return 1;
    }

    fn documentVersion(lua: *Lua) i32 {
        const document = receiver(lua, Runtime.of(lua));
        lua.pushInteger(document.version);

        return 1;
    }

    fn documentLanguage(lua: *Lua) i32 {
        const document = receiver(lua, Runtime.of(lua));
        _ = lua.pushString(document.language);

        return 1;
    }

    fn documentText(lua: *Lua) i32 {
        const document = receiver(lua, Runtime.of(lua));
        _ = lua.pushString(document.bytes());

        return 1;
    }

    fn documentSnapshot(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const document = receiver(lua, runtime);

        const copy = document.snapshot() catch raise.text(lua, "out of memory");
        DocumentHandle.push(lua, runtime, copy);
        copy.release();
        runtime.noteNativeBytes(document.bytes().len);

        return 1;
    }

    fn documentLineCount(lua: *Lua) i32 {
        const document = receiver(lua, Runtime.of(lua));

        lua.pushInteger(@intCast(document.lineCount()));

        return 1;
    }

    fn documentLine(lua: *Lua) i32 {
        const document = receiver(lua, Runtime.of(lua));
        const line_index = lua.checkInteger(2);

        var bounds: ?ByteRange = null;
        if (line_index >= 0) {
            bounds = document.lineBounds(@intCast(line_index));
        }

        if (bounds) |range_in_text| {
            _ = lua.pushString(document.bytes()[range_in_text.start..range_in_text.end]);
        } else {
            lua.pushNil();
        }

        return 1;
    }

    fn documentOffset(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const document = receiver(lua, runtime);
        const position_in_text = positions.read(lua, 2);

        const byte_offset = document.offsetFromPosition(runtime.documents.effectiveEncoding(), position_in_text);
        lua.pushInteger(@intCast(byte_offset));

        return 1;
    }

    fn documentPosition(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const document = receiver(lua, runtime);
        const byte_offset = lua.checkInteger(2);

        const position_in_text = document.positionFromOffset(runtime.documents.effectiveEncoding(), @intCast(@max(byte_offset, 0)));
        positions.push(lua, position_in_text);

        return 1;
    }

    fn documentRange(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const document = receiver(lua, runtime);

        positions.pushRange(lua, document.fullRange(runtime.documents.effectiveEncoding()));

        return 1;
    }
};

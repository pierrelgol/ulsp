const convert = @import("convert.zig");
const registerMetatable = @import("ts.zig").ts_calls.registerMetatable;
const std = @import("std");
const zlua = @import("zlua");
const c = @import("git2");
const Runtime = @import("../Runtime.zig");

const Lua = zlua.Lua;
const raise = convert.raise;
const wrap = zlua.wrap;

pub const RepositoryBox = struct {
    pub const metatable_name = "ulsp.git.repository";

    repository: *c.git_repository,

    fn argument(lua: *Lua) *c.git_repository {
        return lua.checkUserdata(RepositoryBox, 1, metatable_name).repository;
    }

    fn release(lua: *Lua) i32 {
        const box = lua.toUserdata(RepositoryBox, 1) catch return 0;
        c.git_repository_free(box.repository);

        return 0;
    }
};

const status_flags = [_]struct { [:0]const u8, c_uint }{
    .{ "index_new", c.GIT_STATUS_INDEX_NEW },
    .{ "index_modified", c.GIT_STATUS_INDEX_MODIFIED },
    .{ "index_deleted", c.GIT_STATUS_INDEX_DELETED },
    .{ "index_renamed", c.GIT_STATUS_INDEX_RENAMED },
    .{ "index_typechange", c.GIT_STATUS_INDEX_TYPECHANGE },
    .{ "wt_new", c.GIT_STATUS_WT_NEW },
    .{ "wt_modified", c.GIT_STATUS_WT_MODIFIED },
    .{ "wt_deleted", c.GIT_STATUS_WT_DELETED },
    .{ "wt_typechange", c.GIT_STATUS_WT_TYPECHANGE },
    .{ "wt_renamed", c.GIT_STATUS_WT_RENAMED },
    .{ "conflicted", c.GIT_STATUS_CONFLICTED },
};

pub const git_calls = struct {
    pub fn register(lua: *Lua) void {
        // Process-wide and reference counted; never shut down because the server owns the process.
        _ = c.git_libgit2_init();

        lua.pushFunction(wrap(open));
        lua.setField(-2, "git_open");

        registerMetatable(lua, RepositoryBox.metatable_name, .{
            .{ "workdir", workdir },
            .{ "head", head },
            .{ "status", status },
            .{ "show", show },
            .{ "blame", blame },
        }, RepositoryBox.release, null);
    }

    /// Searches upward from `path`; returns nil and the reason when no repository is found.
    fn open(lua: *Lua) i32 {
        const path = lua.checkString(1);

        var maybe_repository: ?*c.git_repository = null;
        if (c.git_repository_open_ext(&maybe_repository, path.ptr, 0, null) != 0) {
            lua.pushNil();
            _ = lua.pushString(lastError());
            return 2;
        }

        const box = lua.newUserdata(RepositoryBox, 0);
        box.* = .{ .repository = maybe_repository orelse unreachable };
        lua.setMetatableRegistry(RepositoryBox.metatable_name);

        return 1;
    }

    fn workdir(lua: *Lua) i32 {
        const maybe_path = c.git_repository_workdir(RepositoryBox.argument(lua));
        if (maybe_path == null) {
            lua.pushNil();
            return 1;
        }

        _ = lua.pushString(std.mem.span(maybe_path));

        return 1;
    }

    /// Returns { name, oid }, or nil on an unborn branch.
    fn head(lua: *Lua) i32 {
        const repository = RepositoryBox.argument(lua);

        var maybe_reference: ?*c.git_reference = null;
        const result = c.git_repository_head(&maybe_reference, repository);
        if (result == c.GIT_EUNBORNBRANCH or result == c.GIT_ENOTFOUND) {
            lua.pushNil();
            return 1;
        }
        if (result != 0) {
            raiseGit(lua, "head");
        }
        defer c.git_reference_free(maybe_reference);

        lua.createTable(0, 2);
        _ = lua.pushString(std.mem.span(c.git_reference_shorthand(maybe_reference)));
        lua.setField(-2, "name");
        _ = lua.pushString(std.mem.span(c.git_oid_tostr_s(c.git_reference_target(maybe_reference))));
        lua.setField(-2, "oid");

        return 1;
    }

    /// Returns an array of { path, <flag> = true, ... } for every changed or untracked file.
    fn status(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const repository = RepositoryBox.argument(lua);
        lua.checkStack(8) catch raise.text(lua, "out of memory");

        var options: c.git_status_options = undefined;
        _ = c.git_status_options_init(&options, c.GIT_STATUS_OPTIONS_VERSION);
        options.flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED | c.GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;

        var maybe_list: ?*c.git_status_list = null;
        if (c.git_status_list_new(&maybe_list, repository, &options) != 0) {
            raiseGit(lua, "status");
        }
        // shortcut: a Lua out-of-memory error below skips this defer and leaks the list; fine until it shows up.
        defer c.git_status_list_free(maybe_list);

        const entry_count = c.git_status_list_entrycount(maybe_list);
        lua.createTable(@intCast(entry_count), 0);
        for (0..entry_count) |index| {
            const entry = c.git_status_byindex(maybe_list, index);
            lua.createTable(0, 2);

            _ = lua.pushString(std.mem.span(entryPath(entry)));
            lua.setField(-2, "path");
            inline for (status_flags) |flag| {
                if (entry.*.status & flag[1] != 0) {
                    lua.pushBoolean(true);
                    lua.setField(-2, flag[0]);
                }
            }

            lua.setIndex(-2, @intCast(index + 1));
        }

        runtime.tags.push(lua, true);
        lua.setMetatable(-2);

        return 1;
    }

    fn entryPath(entry: [*c]const c.git_status_entry) [*c]const u8 {
        if (entry.*.index_to_workdir != null) {
            return entry.*.index_to_workdir.*.new_file.path;
        }

        return entry.*.head_to_index.*.new_file.path;
    }

    /// Returns the content of the blob named by a revision spec such as "HEAD:src/main.zig", or nil.
    fn show(lua: *Lua) i32 {
        const repository = RepositoryBox.argument(lua);
        const spec = lua.checkString(2);

        var maybe_object: ?*c.git_object = null;
        if (c.git_revparse_single(&maybe_object, repository, spec.ptr) != 0) {
            lua.pushNil();
            return 1;
        }
        defer c.git_object_free(maybe_object);

        var maybe_blob: ?*c.git_object = null;
        if (c.git_object_peel(&maybe_blob, maybe_object, c.GIT_OBJECT_BLOB) != 0) {
            lua.pushNil();
            return 1;
        }
        defer c.git_object_free(maybe_blob);

        const blob: ?*c.git_blob = @ptrCast(maybe_blob);
        const maybe_bytes: ?[*]const u8 = @ptrCast(c.git_blob_rawcontent(blob));
        const length: usize = @intCast(c.git_blob_rawsize(blob));
        const bytes = maybe_bytes orelse "";
        _ = lua.pushString(bytes[0..length]);

        return 1;
    }

    /// Returns an array of hunks { start_line, line_count, oid, author, email, time, summary };
    /// `start_line` is 0-based like LSP positions, `path` is relative to the work tree.
    fn blame(lua: *Lua) i32 {
        const runtime = Runtime.of(lua);
        const repository = RepositoryBox.argument(lua);
        const path = lua.checkString(2);
        lua.checkStack(8) catch raise.text(lua, "out of memory");

        var maybe_blame: ?*c.git_blame = null;
        if (c.git_blame_file(&maybe_blame, repository, path.ptr, null) != 0) {
            raiseGit(lua, "blame");
        }
        // shortcut: a Lua out-of-memory error below skips this defer and leaks the blame; fine until it shows up.
        defer c.git_blame_free(maybe_blame);

        const hunk_count = c.git_blame_get_hunk_count(maybe_blame);
        lua.createTable(@intCast(hunk_count), 0);
        for (0..hunk_count) |index| {
            const hunk = c.git_blame_get_hunk_byindex(maybe_blame, @intCast(index));
            pushHunk(lua, hunk);
            lua.setIndex(-2, @intCast(index + 1));
        }

        runtime.tags.push(lua, true);
        lua.setMetatable(-2);

        return 1;
    }

    fn pushHunk(lua: *Lua, hunk: [*c]const c.git_blame_hunk) void {
        lua.createTable(0, 7);

        lua.pushInteger(@intCast(hunk.*.final_start_line_number - 1));
        lua.setField(-2, "start_line");
        lua.pushInteger(@intCast(hunk.*.lines_in_hunk));
        lua.setField(-2, "line_count");
        _ = lua.pushString(std.mem.span(c.git_oid_tostr_s(&hunk.*.final_commit_id)));
        lua.setField(-2, "oid");

        if (hunk.*.final_signature != null) {
            const signature = hunk.*.final_signature.*;
            _ = lua.pushString(std.mem.span(signature.name));
            lua.setField(-2, "author");
            _ = lua.pushString(std.mem.span(signature.email));
            lua.setField(-2, "email");
            lua.pushInteger(signature.when.time);
            lua.setField(-2, "time");
        }
        if (hunk.*.summary != null) {
            _ = lua.pushString(std.mem.span(hunk.*.summary));
            lua.setField(-2, "summary");
        }
    }

    fn lastError() []const u8 {
        const maybe_error = c.git_error_last();
        if (maybe_error == null or maybe_error.*.message == null) {
            return "unknown error";
        }

        return std.mem.span(maybe_error.*.message);
    }

    fn raiseGit(lua: *Lua, comptime what: []const u8) noreturn {
        raise.formatted(lua, "ulsp.git." ++ what ++ ": {s}", .{lastError()});
    }
};

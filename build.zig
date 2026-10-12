const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lua_dep = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua55,
    });

    const lsp_dep = b.dependency("lsp_kit", .{
        .target = target,
        .optimize = optimize,
    });

    const zts_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });

    const zio_dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zio", .module = zio_dep.module("zio") },
            .{ .name = "zlua", .module = lua_dep.module("zlua") },
            .{ .name = "lsp", .module = lsp_dep.module("lsp") },
            .{ .name = "zts", .module = zts_dep.module("tree_sitter") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "ulsp",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);
    b.installDirectory(.{ .source_dir = b.path("tools/lua"), .install_dir = .prefix, .install_subdir = "share/ulsp/lua" });

    // The default config goes to the user's config directory; an existing one is kept.
    const config_tool = b.addExecutable(.{
        .name = "install_config",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/install_config.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const install_config = b.addRunArtifact(config_tool);
    install_config.addArgs(&.{ "keep", "config.lua" });
    install_config.addFileArg(b.path("tools/lua/config.lua"));
    b.getInstallStep().dependOn(&install_config.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run tests");
    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const check_step = b.step("check", "Run checks");
    check_step.dependOn(&exe.step);
}

fn exists(b: *std.Build, path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, b.pathFromRoot(path), .{ .read = true }) catch return false;
    return true;
}

/// { directory suffix, grammar subdirectory, entry point `tree_sitter_<name>` }
const grammars_list = [_]struct { []const u8, []const u8, []const u8 }{
    .{ "agda", "", "agda" },
    .{ "asm", "", "asm" },
    .{ "astro", "", "astro" },
    .{ "awk", "", "awk" },
    .{ "bash", "", "bash" },
    .{ "cmake", "", "cmake" },
    .{ "c", "", "c" },
    .{ "c3", "", "c3" },
    .{ "comment", "", "comment" },
    .{ "commonlisp", "", "commonlisp" },
    .{ "cpp", "", "cpp" },
    .{ "c-sharp", "", "c_sharp" },
    .{ "css", "", "css" },
    .{ "diff", "", "diff" },
    .{ "d", "", "d" },
    .{ "dockerfile", "", "dockerfile" },
    .{ "elixir", "", "elixir" },
    .{ "elm", "", "elm" },
    .{ "fish", "", "fish" },
    .{ "fsharp", "fsharp", "fsharp" },
    .{ "fsharp", "fsharp_signature", "fsharp_signature" },
    .{ "gdscript", "", "gdscript" },
    .{ "gitcommit", "", "gitcommit" },
    .{ "git-rebase", "", "git_rebase" },
    .{ "gleam", "", "gleam" },
    .{ "go", "", "go" },
    .{ "hare", "", "hare" },
    .{ "haskell", "", "haskell" },
    .{ "hcl", "", "hcl" },
    .{ "html", "", "html" },
    .{ "hurl", "", "hurl" },
    .{ "ink", "", "ink" },
    .{ "java", "", "java" },
    .{ "javascript", "", "javascript" },
    .{ "jsdoc", "", "jsdoc" },
    .{ "json", "", "json" },
    .{ "julia", "", "julia" },
    .{ "kdl", "", "kdl" },
    .{ "kotlin", "", "kotlin" },
    .{ "latex", "", "latex" },
    .{ "llvm", "", "llvm" },
    .{ "lua", "", "lua" },
    .{ "mail", "", "mail" },
    .{ "make", "", "make" },
    .{ "markdown", "tree-sitter-markdown", "markdown" },
    .{ "markdown", "tree-sitter-markdown-inline", "markdown_inline" },
    .{ "nasm", "", "nasm" },
    .{ "nickel", "", "nickel" },
    .{ "nim", "", "nim" },
    .{ "ninja", "", "ninja" },
    .{ "nix", "", "nix" },
    .{ "nu", "", "nu" },
    .{ "objc", "", "objc" },
    .{ "ocaml", "grammars/interface", "ocaml_interface" },
    .{ "ocaml", "grammars/ocaml", "ocaml" },
    .{ "ocaml", "grammars/type", "ocaml_type" },
    .{ "odin", "", "odin" },
    .{ "openscad", "", "openscad" },
    .{ "org", "", "org" },
    .{ "perl", "", "perl" },
    .{ "php", "php", "php" },
    .{ "po", "", "po" },
    .{ "powershell", "", "powershell" },
    .{ "proto", "", "proto" },
    .{ "purescript", "", "purescript" },
    .{ "python", "", "python" },
    .{ "query", "", "query" },
    .{ "regex", "", "regex" },
    .{ "rpmspec", "rpmbash", "rpmbash" },
    .{ "rpmspec", "rpmspec", "rpmspec" },
    .{ "rst", "", "rst" },
    .{ "ruby", "", "ruby" },
    .{ "rust", "", "rust" },
    .{ "scala", "", "scala" },
    .{ "scheme", "", "scheme" },
    .{ "sql", "", "sql" },
    .{ "ssh-config", "", "ssh_config" },
    .{ "superhtml", "tree-sitter-superhtml", "superhtml" },
    .{ "swift", "", "swift" },
    .{ "systemverilog", "", "systemverilog" },
    .{ "toml", "", "toml" },
    .{ "typescript", "tsx", "tsx" },
    .{ "typescript", "typescript", "typescript" },
    .{ "typst", "", "typst" },
    .{ "uxntal", "", "uxntal" },
    .{ "v", "tree_sitter_v", "v" },
    .{ "vim", "", "vim" },
    .{ "vue", "", "vue" },
    .{ "wikitext", "", "wikitext" },
    .{ "xml", "dtd", "dtd" },
    .{ "xml", "xml", "xml" },
    .{ "yaml", "", "yaml" },
    .{ "ziggy", "tree-sitter-ziggy", "ziggy" },
    .{ "ziggy", "tree-sitter-ziggy-schema", "ziggy_schema" },
    .{ "zig", "", "zig" },
};

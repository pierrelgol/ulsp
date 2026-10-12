# ulsp

A language server you script in Lua. Handlers, tree-sitter queries and async tasks run in an embedded Lua runtime.
ulsp speaks LSP over stdio.

Written in Zig (0.16+).
Uses [ziglua](https://github.com/natecraddock/ziglua),
[lsp-kit](https://github.com/pierrelgol/lsp-kit),
[zio](https://github.com/lalinsky/zio)
[zig-tree-sitter](https://github.com/tree-sitter/zig-tree-sitter).

## Build

```sh
zig build
```

This also builds the tree-sitter grammars as shared libraries and installs the Lua files and a default config.

## Use

Point your editor at the `ulsp` binary as an LSP server over stdio. Load a config with `ULSP_CONFIG`:

```sh
ULSP_CONFIG=examples/init.lua ulsp
```

A handler:

```lua
ulsp.on("textDocument/hover", function(p)
  local doc = ulsp.docs.get(p.textDocument.uri)
  if not doc then return ulsp.null end
  return { contents = { kind = "markdown", value = doc:language() } }
end)
```

See [`examples/`](examples) for hover, formatting and document symbols (`demo.lua` shows more).

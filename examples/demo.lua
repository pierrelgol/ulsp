-- ulsp demo config: a guided tour, in the spirit of nvim-kickstart.
--
-- Try it:   ULSP_CONFIG=examples/demo.lua ulsp        (your editor starts it over stdio)
--
-- Read it top to bottom. Every feature is branded "🦄 ulsp" so you can tell it apart from other
-- servers. It works for any language that has a tree-sitter grammar installed.
--
-- Lines starting with `--| ` are working code that is switched off: delete the `--| ` (keep the
-- code) to turn them on. Plain `-- ` lines are explanations.
--
-- The model, in four sentences:
--   * `ulsp` is a global table; this file runs once, during `initialize`.
--   * `ulsp.on("lsp/method", fn)` registers a handler. Requests return their result (or call
--     `error(...)`); notifications ignore the return value.
--   * Handlers run as coroutines: `ulsp.process.run`, `ulsp.fs.*`, `ulsp.sleep`, `ulsp.rpc.request`
--     and `:await()` look blocking but only pause that handler, never the server.
--   * A handler for a method automatically advertises the matching capability. Use
--     `ulsp.capabilities` only for extra options (see the completion trigger characters below).

-- ---------------------------------------------------------------------------------------------
-- 1. Settings
-- ---------------------------------------------------------------------------------------------

-- Where the grammars live. `zig build` installs lib<name>.so files here.
local parser_dir = os.getenv("ULSP_PARSER_DIR") or (os.getenv("HOME") .. "/.config/ulsp/runtime/parsers")

-- Log verbosity: "error" | "warn" | "info" | "debug". Logs go to stderr and to the editor's log.
--| ulsp.log.set_level("debug")

-- Server-wide options. `ulsp.capabilities` is merged into what the handlers advertise.
ulsp.capabilities.completionProvider = { triggerCharacters = { "_" } }

-- Other things you can read: ulsp.version, ulsp.root (first workspace folder, or nil),
-- ulsp.workspace_folders (list of paths), ulsp.initialize_params (what the editor sent),
-- ulsp.encoding() ("utf-16" or "utf-8": how LSP columns are counted).
--| ulsp.log.info("root:", ulsp.root, "encoding:", ulsp.encoding())

-- ---------------------------------------------------------------------------------------------
-- 2. Tree-sitter: grammar per language, parse trees, symbols
-- ---------------------------------------------------------------------------------------------

-- `ulsp.ts.load(name, path)` loads a grammar once (later calls return the same language) and
-- raises if the file is missing, hence the pcall. We use the document's languageId as the name,
-- so "python" loads libpython.so. A language with no grammar is cached as `false`.
local langs = {}
local function lang_of(doc)
  local id = doc:language()
  if langs[id] == nil then
    local ok, l = pcall(ulsp.ts.load, id, parser_dir .. "/lib" .. id .. ".so")
    langs[id] = ok and l or false
  end
  return langs[id]
end

-- `ulsp.ts.tree(uri_or_doc, language)` returns the incrementally-updated parse tree of an open
-- document (nil if it is not open). Never parse by hand on every keystroke.
local function tree_of(doc)
  local l = lang_of(doc)
  return l and ulsp.ts.tree(doc:uri(), l)
end

-- Nodes: n:type(), n:text(), n:range() (an LSP range, ready to return), n:field("name"),
-- n:parent(), n:children(), n:named_children(), n:child_count(), n:has_error(),
-- n:descendant_for_range(a, b) with byte offsets, n:sexp() to print the s-expression.
--
-- Here is a language-agnostic "symbol": a function/method/class/struct-like node that has a
-- name. Most grammars use a `name` field; C-style ones hide it at the end of a `declarator` chain.
-- This is a heuristic on node type names. For exact control, use a query (next block).
local function symbol_name(node)
  local t = node:type()
  if t:find("declarator") or not (t:find("function") or t:find("method") or t:find("class") or t:find("struct")) then
    return nil
  end
  local n = node:field("name")
  if not n then
    n = node:field("declarator")
    while n and n:field("declarator") do n = n:field("declarator") end
  end
  return n
end

local function symbols_of(node, out)
  out = out or {}
  local name = symbol_name(node)
  if name then
    local t = node:type()
    out[#out + 1] = { node = node, name = name, kind = t:find("class") and 5 or t:find("struct") and 23 or 12 }
  end
  for _, child in ipairs(node:named_children()) do symbols_of(child, out) end
  return out
end

-- Queries are the precise alternative: write the tree-sitter pattern for your language, then
-- `query:matches(root)` gives one table per match keyed by capture name (m.name, m.def), and
-- `query:captures(root)` gives a flat list of { capture_name, node }. Example for C:
--|local c = ulsp.ts.load("c", parser_dir .. "/libc.so")
--|local c_functions = ulsp.ts.query(c, [[
--|  (function_definition declarator: (function_declarator declarator: (identifier) @name)) @def
--|]])
--|-- ... later, with a C document's tree:
--|for _, m in ipairs(c_functions:matches(tree:root())) do print(m.name:text()) end

-- ---------------------------------------------------------------------------------------------
-- 3. Hover, completion, symbols, code lens
-- ---------------------------------------------------------------------------------------------

local function uri_of(p) return p.textDocument.uri end

-- `ulsp.docs.get(uri)` returns an open document (or nil): doc:text(), doc:line(n),
-- doc:line_count(), doc:language(), doc:uri(), doc:version(), doc:range() (whole file),
-- doc:offset(position) -> byte offset, doc:position(offset) -> LSP position.
-- `ulsp.docs.list()` lists every open document.
ulsp.on("textDocument/hover", function(p)
  local doc = ulsp.docs.get(uri_of(p))
  local tree = doc and tree_of(doc)
  if not tree then return ulsp.null end -- `ulsp.null` is JSON null ("nothing here")
  local off = doc:offset(p.position)
  local node = tree:root():descendant_for_range(off, off)
  local fn = node
  while fn and not symbol_name(fn) do fn = fn:parent() end
  local where = "top level"
  if fn then where = "in `" .. symbol_name(fn):text() .. "`" end
  local lines = {
    "### 🦄 ulsp hover",
    "`" .. node:text():sub(1, 60) .. "` is a **" .. node:type() .. "** (" .. where .. ")",
    "line " .. (p.position.line + 1) .. " of " .. doc:line_count() .. " · " .. ulsp.encoding(),
  }
  -- Run a program and use its output. `ulsp.process.run` returns { code, stdout, stderr }.
  --| local git = ulsp.process.run({ cmd = { "git", "rev-parse", "--abbrev-ref", "HEAD" }, cwd = ulsp.root })
  --| if git.code == 0 then lines[#lines + 1] = "git branch: " .. git.stdout end
  return { contents = { kind = "markdown", value = table.concat(lines, "\n\n") }, range = node:range() }
end)

-- Lists in a result must be JSON arrays even when empty: build them with `ulsp.json.array({})`
-- (a plain empty Lua table would become `{}`). `ulsp.json.object({})` is the opposite.
ulsp.on("textDocument/completion", function(p)
  local doc = ulsp.docs.get(uri_of(p))
  local items = ulsp.json.array({})
  local function add(label, detail, kind) items[#items + 1] = { label = label, detail = detail, kind = kind } end
  add("ulsp_hello", "🦄 from ulsp", 3) -- 3 = Function, 21 = Constant, 6 = Variable (LSP CompletionItemKind)
  add("ulsp_version", "ulsp " .. ulsp.version, 21)
  local tree = doc and tree_of(doc)
  if tree then
    local seen = {}
    local function walk(node)
      if node:type():find("identifier") and node:child_count() == 0 then
        local text = node:text()
        if not seen[text] then seen[text] = true add(text, "🦄 identifier in this file", 6) end
      end
      for _, child in ipairs(node:named_children()) do walk(child) end
    end
    walk(tree:root())
  end
  return { isIncomplete = false, items = items }
end)

local function doc_symbols(doc)
  local tree = tree_of(doc)
  return tree and symbols_of(tree:root()) or {}
end

ulsp.on("textDocument/documentSymbol", function(p)
  local doc = ulsp.docs.get(uri_of(p))
  local symbols = ulsp.json.array({})
  for _, m in ipairs(doc and doc_symbols(doc) or {}) do
    symbols[#symbols + 1] = { name = m.name:text(), detail = "🦄 ulsp", kind = m.kind,
      range = m.node:range(), selectionRange = m.name:range() }
  end
  return symbols
end)

-- Code lens: a clickable label above a line. `command` is run by the editor; "ulsp.noop" is
-- just a placeholder name.
ulsp.on("textDocument/codeLens", function(p)
  local doc = ulsp.docs.get(uri_of(p))
  local lenses = ulsp.json.array({})
  for _, m in ipairs(doc and doc_symbols(doc) or {}) do
    local r = m.name:range()
    lenses[#lenses + 1] = { range = { start = r.start, ["end"] = r.start },
      command = { title = "🦄 ulsp: " .. m.node:type() .. " " .. m.name:text(), command = "ulsp.noop" } }
  end
  return lenses
end)

-- ---------------------------------------------------------------------------------------------
-- 4. Diagnostics: the server pushes them with a notification
-- ---------------------------------------------------------------------------------------------

-- Here: TODO/FIXME comments (any language, plain text scan) and tree-sitter syntax errors.
-- Severity: 1 error, 2 warning, 3 information, 4 hint.
local function publish(uri)
  local doc = ulsp.docs.get(uri)
  if not doc then return end
  local list = ulsp.json.array({})
  for n = 0, doc:line_count() - 1 do
    local line = doc:line(n)
    local s, e, word = line:find("(%u%u%u%u+):")
    if word == "TODO" or word == "FIXME" then
      local a = doc:position(doc:offset({ line = n, character = 0 }) + s - 1)
      local b = doc:position(doc:offset({ line = n, character = 0 }) + e)
      list[#list + 1] = { range = { start = a, ["end"] = b }, severity = word == "FIXME" and 2 or 3,
        source = "ulsp", message = "🦄 ulsp noticed a " .. word }
    end
  end
  local tree = tree_of(doc)
  if tree and tree:root():has_error() then
    list[#list + 1] = { range = tree:root():range(), severity = 1, source = "ulsp",
      message = "🦄 ulsp: syntax error somewhere in this file" }
  end
  ulsp.rpc.notify("textDocument/publishDiagnostics", { uri = uri, diagnostics = list })
end
ulsp.on("textDocument/didOpen", function(p) publish(uri_of(p)) end)
ulsp.on("textDocument/didChange", function(p) publish(uri_of(p)) end)
ulsp.on("textDocument/didClose", function(p)
  ulsp.rpc.notify("textDocument/publishDiagnostics", { uri = uri_of(p), diagnostics = ulsp.json.array({}) })
end)

-- `ulsp.on` replaces a handler; `ulsp.add` stacks another one. Every notification handler runs,
-- so you can split concerns without touching the code above:
--| ulsp.add("textDocument/didOpen", function(p) ulsp.log.info("opened", ulsp.uri.to_path(uri_of(p))) end)

-- didSave is only delivered if a handler exists (the capability is advertised for you).
--| ulsp.on("textDocument/didSave", function(p)
--|   -- Server -> editor notification: a popup. type: 1 error, 2 warning, 3 info, 4 log.
--|   ulsp.rpc.notify("window/showMessage", { type = 3, message = "🦄 saved " .. ulsp.uri.to_path(uri_of(p)) })
--| end)

-- ---------------------------------------------------------------------------------------------
-- 5. Formatting: external process, with a timeout
-- ---------------------------------------------------------------------------------------------

-- `ulsp.async(fn, ...)` starts a concurrent task and returns a future. `<close>` cancels it when
-- the scope ends. `ulsp.select(a, b)` waits for the first future to finish and returns it, so
-- "job vs. timer" is a race. `fut:await()` returns the result or re-raises its error.
ulsp.on("textDocument/formatting", function(p)
  local doc = ulsp.docs.get(uri_of(p))
  if not doc then return ulsp.null end
  local clang = ({ c = 1, cpp = 1, objc = 1 })[doc:language()]
  local cmd = clang and ulsp.fs.stat("/usr/bin/clang-format") and { "clang-format" } or { "sed", "s/[ \t]*$//" }
  local job   <close> = ulsp.async(ulsp.process.run, { cmd = cmd, stdin = doc:text() })
  local timer <close> = ulsp.async(ulsp.sleep, 3000)
  if ulsp.select(job, timer) == timer then error("formatter timed out", 0) end
  local out = job:await()
  if out.code ~= 0 then error(out.stderr, 0) end
  -- A text edit replacing the whole document. Editors diff it for you.
  return { { range = doc:range(), newText = out.stdout } }
end)

-- Errors: `error("message", 0)` becomes an LSP error shown to the user. To pick the LSP code
-- yourself, raise a table: error({ code = -32803, message = "nope" }, 0).

-- ---------------------------------------------------------------------------------------------
-- 6. More things to try (all off; remove `--| ` to enable)
-- ---------------------------------------------------------------------------------------------

-- Go to definition, same file only: find a symbol whose name equals the word under the cursor.
--| ulsp.on("textDocument/definition", function(p)
--|   local doc = ulsp.docs.get(uri_of(p))
--|   local tree = doc and tree_of(doc)
--|   if not tree then return ulsp.null end
--|   local off = doc:offset(p.position)
--|   local word = tree:root():descendant_for_range(off, off):text()
--|   for _, s in ipairs(symbols_of(tree:root())) do
--|     if s.name:text() == word then return { uri = doc:uri(), range = s.name:range() } end
--|   end
--|   return ulsp.null
--| end)

-- Code action: a lightbulb entry that edits the file. `changes` maps a uri to a list of edits.
--| ulsp.on("textDocument/codeAction", function(p)
--|   local top = { line = 0, character = 0 }
--|   return { {
--|     title = "🦄 ulsp: add a banner",
--|     kind = "quickfix",
--|     edit = { changes = { [uri_of(p)] = { { range = { start = top, ["end"] = top }, newText = "🦄 hello from ulsp\n" } } } },
--|   } }
--| end)

-- Files are suspending calls too: ulsp.fs.read(path), ulsp.fs.write(path, data),
-- ulsp.fs.stat(path) (nil if missing), ulsp.fs.list(path).
--| ulsp.on("workspace/didChangeWatchedFiles", function() ulsp.log.info("files changed on disk") end)

-- Ask the editor something: `ulsp.rpc.request` waits for the reply (it can be slow, so call it
-- from a handler, never at the top level of this file).
--| ulsp.add("textDocument/didSave", function()
--|   local choice = ulsp.rpc.request("window/showMessageRequest", {
--|     type = 3, message = "🦄 format now?", actions = { { title = "yes" }, { title = "no" } } })
--|   ulsp.log.info("user chose", choice ~= ulsp.null and choice.title or "nothing")
--| end)

-- Fan out work and wait for all of it: a group cancels its members together.
--| local function check_all(paths)
--|   local g = ulsp.group()
--|   for _, path in ipairs(paths) do g:async(ulsp.fs.read, path) end
--|   return g:await()
--| end

-- Split a big config: `require("name")` loads name.lua from this file's directory (see
-- examples/init.lua, which requires hover, format and symbols).

ulsp.log.info("🦄 ulsp demo config loaded")

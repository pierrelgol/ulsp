-- Demo configuration for C files. Every feature is branded "ulsp" so you can tell it apart
-- from clangd and friends: hover, completion, diagnostics, symbols, code lens, formatting.
local home = os.getenv("HOME")
local parser = os.getenv("ULSP_C_PARSER") or (home .. "/.config/ulsp/runtime/parsers/libc.so")
local c = ulsp.ts.load("c", parser)
local functions = ulsp.ts.query(c, [[
  (function_definition declarator: (function_declarator declarator: (identifier) @name)) @def
]])
local identifiers = ulsp.ts.query(c, "(identifier) @id")

ulsp.capabilities.completionProvider = { triggerCharacters = { "_" } }

local function uri_of(p) return p.textDocument.uri end

-- hover: banner, node under the cursor, and the enclosing function
ulsp.on("textDocument/hover", function(p)
  local doc = ulsp.docs.get(uri_of(p))
  local tree = doc and ulsp.ts.tree(doc:uri(), c)
  if not tree then return ulsp.null end
  local off = doc:offset(p.position)
  local node = tree:root():descendant_for_range(off, off)
  local fn = node
  while fn and fn:type() ~= "function_definition" do fn = fn:parent() end
  local where = "top level"
  if fn then where = "in `" .. fn:field("declarator"):field("declarator"):text() .. "()`" end
  return { contents = { kind = "markdown", value = table.concat({
    "### 🦄 ulsp hover",
    "`" .. node:text():sub(1, 60) .. "` is a **" .. node:type() .. "** (" .. where .. ")",
    "line " .. (p.position.line + 1) .. " of " .. doc:line_count() .. " · " .. ulsp.encoding(),
  }, "\n\n") }, range = node:range() }
end)

-- completion: our own items, then every identifier in the file
ulsp.on("textDocument/completion", function(p)
  local doc = ulsp.docs.get(uri_of(p))
  local items = ulsp.json.array({})
  local function add(label, detail, kind)
    items[#items + 1] = { label = label, detail = detail, kind = kind }
  end
  add("ulsp_hello", "🦄 from ulsp", 3)
  add("ulsp_version", "ulsp " .. ulsp.version, 21)
  local tree = doc and ulsp.ts.tree(doc:uri(), c)
  if tree then
    local seen = {}
    for _, cap in ipairs(identifiers:captures(tree:root())) do
      local text = cap[2]:text()
      if not seen[text] then seen[text] = true add(text, "🦄 identifier in this file", 6) end
    end
  end
  return { isIncomplete = false, items = items }
end)

-- symbols and code lens
local function function_matches(doc)
  local tree = ulsp.ts.tree(doc:uri(), c)
  return tree and functions:matches(tree:root()) or {}
end

ulsp.on("textDocument/documentSymbol", function(p)
  local doc = ulsp.docs.get(uri_of(p))
  local symbols = ulsp.json.array({})
  for _, m in ipairs(doc and function_matches(doc) or {}) do
    symbols[#symbols + 1] = { name = m.name:text(), detail = "🦄 ulsp", kind = 12,
      range = m.def:range(), selectionRange = m.name:range() }
  end
  return symbols
end)

ulsp.on("textDocument/codeLens", function(p)
  local doc = ulsp.docs.get(uri_of(p))
  local lenses = ulsp.json.array({})
  for _, m in ipairs(doc and function_matches(doc) or {}) do
    local r = m.name:range()
    lenses[#lenses + 1] = { range = { start = r.start, ["end"] = r.start },
      command = { title = "🦄 ulsp: function " .. m.name:text(), command = "ulsp.noop" } }
  end
  return lenses
end)

-- diagnostics: TODO/FIXME comments and syntax errors, published on open and change
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
  local tree = ulsp.ts.tree(uri, c)
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

-- formatting: clang-format if present, else trim trailing whitespace; 3 s timeout
ulsp.on("textDocument/formatting", function(p)
  local doc = ulsp.docs.get(uri_of(p))
  if not doc then return ulsp.null end
  local cmd = ulsp.fs.stat("/usr/bin/clang-format") and { "clang-format" } or { "sed", "s/[ \t]*$//" }
  local job   <close> = ulsp.async(ulsp.process.run, { cmd = cmd, stdin = doc:text() })
  local timer <close> = ulsp.async(ulsp.sleep, 3000)
  if ulsp.select(job, timer) == timer then error("formatter timed out", 0) end
  local out = job:await()
  if out.code ~= 0 then error(out.stderr, 0) end
  return { { range = doc:range(), newText = out.stdout } }
end)

ulsp.log.info("🦄 ulsp demo config loaded")

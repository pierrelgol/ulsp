-- Function symbols of C files, from tree-sitter. ULSP_C_PARSER is the path of the C grammar.
local path = os.getenv("ULSP_C_PARSER")
if not path then
  ulsp.log.info("ULSP_C_PARSER is not set: no document symbols")
  return
end
local c = ulsp.ts.load("c", path)
local functions = ulsp.ts.query(c, [[
  (function_definition declarator: (function_declarator declarator: (identifier) @name)) @def
]])

ulsp.on("textDocument/documentSymbol", function(p)
  local tree = ulsp.ts.tree(p.textDocument.uri, c)
  if not tree then return ulsp.null end
  local symbols = ulsp.json.array({})
  for _, m in ipairs(functions:matches(tree:root())) do
    symbols[#symbols + 1] = { name = m.name:text(), kind = 12, range = m.def:range(), selectionRange = m.name:range() }
  end
  return symbols
end)

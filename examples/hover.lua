-- The word under the cursor and the document's language.
ulsp.on("textDocument/hover", function(p)
  local doc = ulsp.docs.get(p.textDocument.uri)
  if not doc then return ulsp.null end
  local line = doc:line(p.position.line) or ""
  local word = line:match("[%w_]+") or "?"
  return { contents = { kind = "markdown", value = "`" .. word .. "` (" .. doc:language() .. ")" } }
end)

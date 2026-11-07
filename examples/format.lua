-- Formats with an external program, killed after a timeout.
-- ULSP_FORMAT_SH and ULSP_FORMAT_TIMEOUT (milliseconds) exist so the tests can use `sh`.
local cmd = { "stylua", "-" }
if os.getenv("ULSP_FORMAT_SH") then cmd = { "sh", "-c", os.getenv("ULSP_FORMAT_SH") } end
local timeout = tonumber(os.getenv("ULSP_FORMAT_TIMEOUT")) or 2000

ulsp.on("textDocument/formatting", function(p)
  local doc = ulsp.docs.get(p.textDocument.uri)
  if not doc then return ulsp.null end
  local job   <close> = ulsp.async(ulsp.process.run, { cmd = cmd, stdin = doc:text() })
  local timer <close> = ulsp.async(ulsp.sleep, timeout)
  if ulsp.select(job, timer) == timer then error(cmd[1] .. " timed out", 0) end
  local out = job:await()
  if out.code ~= 0 then error(out.stderr, 0) end
  return { { range = doc:range(), newText = out.stdout } }
end)

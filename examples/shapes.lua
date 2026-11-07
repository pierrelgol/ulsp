-- Tensor shapes as inlay hints at the end of each line of a ZML model, from a shape trace.
--
--   require("shapes")   -- from config.lua
--
-- The trace is written by zml when ZML_SHAPE_TRACE is set (see zml/zml/shape_trace.zig), for
-- example by `bazel run //examples/llm:trace_shapes -- --model=<repo>`. It maps each source line
-- to the shapes it produced. This file is read from $ZML_SHAPES, else
-- <workspace>/.zig-cache/zml-shapes.json, and reloaded when it changes.
--
-- A hint is only shown while the file is exactly what was traced: saved, and not modified since
-- the trace. A hint on a shifted line would be wrong, and a wrong hint is worse than none.
--
-- Set ZML_SHAPES_RETRACE to a shell command to retrace on save, e.g.
--   ZML_SHAPES_RETRACE='bazel run //examples/llm:trace_shapes -- --model=$HOME/models/llama'

local log = ulsp.log

local max_shapes = 2  -- distinct shapes shown per line; more are summarized as "+n"

local trace = { path = nil, mtime = nil, files = {} }
local disk = {}         -- path -> { version, matches } whether the open document equals the file
local retrace_running = false

local function root() return ulsp.root end

local function trace_path()
  local env = os.getenv("ZML_SHAPES")
  if env and env ~= "" then return env end
  return root() and root() .. "/.zig-cache/zml-shapes.json"
end

-- Reloads the trace when its file changed. Returns its mtime, or nil without a trace.
local function load_trace()
  local path = trace_path()
  if not path then return nil end
  local stat = ulsp.fs.stat(path)
  if not stat then
    trace = { path = path, files = {} }
    return nil
  end
  if trace.path ~= path or trace.mtime ~= stat.mtime then
    local ok, data = pcall(function() return ulsp.json.decode(ulsp.fs.read(path)) end)
    if ok and type(data) == "table" and type(data.files) == "table" then
      trace = { path = path, mtime = stat.mtime, files = data.files, label = data.label }
      local count = 0
      for _ in pairs(data.files) do count = count + 1 end
      log.info(string.format("shapes: loaded %s (%d files)", path, count))
    else
      log.warn("shapes: cannot read " .. path)
      trace = { path = path, mtime = stat.mtime, files = {} }
    end
  end
  return trace.mtime
end

local function relative(path)
  local r = root()
  if r and path:sub(1, #r + 1) == r .. "/" then return path:sub(#r + 2) end
end

-- Whether the open document is what was traced: same text as on disk, and the file on disk is not
-- newer than the trace.
local function traced_as_is(doc, path, trace_mtime)
  local stat = ulsp.fs.stat(path)
  if not stat or stat.mtime > trace_mtime then return false end
  local cached = disk[path]
  if cached and cached.version == doc:version() and cached.mtime == stat.mtime then return cached.matches end
  local ok, text = pcall(ulsp.fs.read, path)
  local matches = ok and text == doc:text()
  disk[path] = { version = doc:version(), mtime = stat.mtime, matches = matches }
  return matches
end

local function label(shapes)
  local parts = {}
  for i = 1, math.min(#shapes, max_shapes) do parts[i] = shapes[i][1] end
  local text = table.concat(parts, " · ")
  if #shapes > max_shapes then text = text .. string.format(" +%d", #shapes - max_shapes) end
  return text
end

ulsp.on("textDocument/inlayHint", function(p)
  local hints = ulsp.json.array({})
  local doc = ulsp.docs.get(p.textDocument.uri)
  local path = doc and ulsp.uri.to_path(doc:uri())
  local rel = path and relative(path)
  if not rel then return hints end
  local trace_mtime = load_trace()
  local lines = trace_mtime and trace.files[rel]
  if not lines or not traced_as_is(doc, path, trace_mtime) then return hints end

  local first, last = p.range.start.line, p.range["end"].line
  for line_text, shapes in pairs(lines) do
    local line = tonumber(line_text) - 1
    if line >= first and line <= last then
      local text = doc:line(line)
      if text then
        text = text:gsub("[\r\n]+$", "")
        local at = doc:position(doc:offset({ line = line, character = 0 }) + #text)
        local tooltip = {}
        for _, s in ipairs(shapes) do tooltip[#tooltip + 1] = string.format("%s ×%d", s[1], s[2]) end
        hints[#hints + 1] = {
          position = at, label = label(shapes), kind = 1, paddingLeft = true,
          tooltip = table.concat(tooltip, "\n") .. (trace.label and trace.label ~= "" and "\ntraced: " .. trace.label or ""),
        }
      end
    end
  end
  return hints
end)

-- Retrace on save, when a command is configured, then ask the editor for fresh hints.
ulsp.add("textDocument/didSave", function(p)
  local command = os.getenv("ZML_SHAPES_RETRACE")
  if not command or command == "" or retrace_running then return end
  local path = ulsp.uri.to_path(p.textDocument.uri) or ""
  if not path:match("%.zig$") then return end
  retrace_running = true
  local ok, out = pcall(ulsp.process.run, { cmd = { "sh", "-c", command }, cwd = root() })
  retrace_running = false
  if not ok or out.code ~= 0 then
    log.warn("shapes: retrace failed: " .. (ok and out.stderr:sub(-800) or tostring(out)))
    return
  end
  disk = {}
  pcall(ulsp.rpc.request, "workspace/inlayHint/refresh", ulsp.null)
end)

log.info("shapes: loaded")

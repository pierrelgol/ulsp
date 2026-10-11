-- ulsp prelude. Receives `core` and the scheduler `S`;
-- returns on_message and on_completion.
local core, S = ...

local null = core.null

local ulsp = {
  version = "0.1.0",
  capabilities = {},
  null = null,
  canceled = S.canceled,
  async = S.async,
  select = S.select,
  sleep = S.sleep,
  group = S.group,
  json = {
    array = core.array, object = core.object,
    encode = core.json_encode, decode = core.json_decode,
  },
  uri = { to_path = core.uri_to_path, from_path = core.uri_from_path },
  docs = { get = core.doc_get, list = core.doc_list },
  -- filled in by lua/ts.zig; nil until then
  ts = {
    load = core.ts_load, language = core.ts_language, parse = core.ts_parse,
    tree = core.ts_tree, query = core.ts_query,
  },
  rpc = {},
  log = {},
  process = {},
  fs = {},
}

local state = "uninitialized" -- uninitialized | initializing | running | shutdown
local encoding
local handlers = {}
local inflight = {}  -- request id -> future
local pending = {}   -- id of a server request -> waiting task

function ulsp.encoding() return encoding end

local function send(msg) return core.send(msg) end

local log_level = 3
function ulsp.log.set_level(name)
  for level, n in ipairs({ "error", "warn", "info", "debug" }) do
    if n == name then log_level = level return end
  end
  error("ulsp.log.set_level: expected error, warn, info or debug", 2)
end

for level, name in ipairs({ "error", "warn", "info", "debug" }) do
  ulsp.log[name] = function(...)
    if level > log_level then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    local text = table.concat(parts, "\t")
    core.log(level, text)
    if state ~= "uninitialized" then
      pcall(send, { jsonrpc = "2.0", method = "window/logMessage", params = { type = level, message = text } })
    end
  end
end
local log = ulsp.log
print = log.info

local function reply_error(id, code, message, data)
  if id == nil then id = null end
  -- send() rejects invalid UTF-8; an unsent error reply would leave the request hanging.
  if type(message) == "string" and not utf8.len(message) then message = "error text is not valid UTF-8" end
  send({ jsonrpc = "2.0", id = id, error = { code = code, message = message, data = data } })
end

local function respond(id, result)
  if result == nil then result = null end
  local ok, err = pcall(send, { jsonrpc = "2.0", id = id, result = result })
  if not ok then
    log.error("cannot convert result of request " .. tostring(id) .. ": " .. tostring(err))
    reply_error(id, -32603, tostring(err))
  end
end

function ulsp.on(method, fn)
  if type(method) ~= "string" then error("ulsp.on: method must be a string", 2) end
  if fn ~= nil and type(fn) ~= "function" then error("ulsp.on: handler must be a function or nil", 2) end
  handlers[method] = fn and { fn } or nil
end

-- Adds a handler after the existing ones. Notifications run every handler, each in its own
-- task; a request uses the first one only.
function ulsp.add(method, fn)
  if type(method) ~= "string" then error("ulsp.add: method must be a string", 2) end
  if type(fn) ~= "function" then error("ulsp.add: handler must be a function", 2) end
  local list = handlers[method]
  if not list then handlers[method] = { fn } else list[#list + 1] = fn end
end

function ulsp.rpc.notify(method, params)
  if type(method) ~= "string" then error("ulsp.rpc.notify: method must be a string", 2) end
  send({ jsonrpc = "2.0", method = method, params = params })
end

local next_request_id = 0
function ulsp.rpc.request(method, params)
  if type(method) ~= "string" then error("ulsp.rpc.request: method must be a string", 2) end
  local task = S.check()
  next_request_id = next_request_id + 1
  local id = next_request_id
  pending[id] = task
  local ok, err = pcall(send, { jsonrpc = "2.0", id = id, method = method, params = params })
  if not ok then
    pending[id] = nil
    error(err, 0)
  end
  local response = S.suspend(function()
    pending[id] = nil -- a later response is ignored
    pcall(send, { jsonrpc = "2.0", method = "$/cancelRequest", params = { id = id } })
  end)
  if response.error ~= nil then
    local e = response.error
    error({ code = e.code, message = e.message, data = e.data }, 0)
  end
  if response.result == nil then return null end
  return response.result
end

function ulsp.process.run(spec) return S.op("op_run", spec) end
function ulsp.fs.read(path) return S.op("op_read", path) end
function ulsp.fs.write(path, data) S.op("op_write", path, data) end
function ulsp.fs.stat(path) return S.op("op_stat", path) or nil end
function ulsp.fs.list(path) return S.op("op_list", path) end

local capability_keys = {
  ["textDocument/hover"] = { "hoverProvider", true },
  ["textDocument/completion"] = { "completionProvider", {} },
  ["textDocument/signatureHelp"] = { "signatureHelpProvider", {} },
  ["textDocument/declaration"] = { "declarationProvider", true },
  ["textDocument/definition"] = { "definitionProvider", true },
  ["textDocument/typeDefinition"] = { "typeDefinitionProvider", true },
  ["textDocument/implementation"] = { "implementationProvider", true },
  ["textDocument/references"] = { "referencesProvider", true },
  ["textDocument/documentHighlight"] = { "documentHighlightProvider", true },
  ["textDocument/documentSymbol"] = { "documentSymbolProvider", true },
  ["textDocument/codeAction"] = { "codeActionProvider", true },
  ["textDocument/codeLens"] = { "codeLensProvider", {} },
  ["textDocument/documentLink"] = { "documentLinkProvider", {} },
  ["textDocument/formatting"] = { "documentFormattingProvider", true },
  ["textDocument/rangeFormatting"] = { "documentRangeFormattingProvider", true },
  ["textDocument/rename"] = { "renameProvider", true },
  ["textDocument/foldingRange"] = { "foldingRangeProvider", true },
  ["textDocument/selectionRange"] = { "selectionRangeProvider", true },
  ["textDocument/inlayHint"] = { "inlayHintProvider", true },
  ["workspace/symbol"] = { "workspaceSymbolProvider", true },
  ["textDocument/prepareCallHierarchy"] = { "callHierarchyProvider", true },
  ["textDocument/linkedEditingRange"] = { "linkedEditingRangeProvider", true },
}

local function is_object(t)
  return type(t) == "table" and #t == 0
end

local function merge(into, from)
  for k, v in pairs(from) do
    local cur = into[k]
    if is_object(cur) and is_object(v) then
      merge(cur, v)
    else
      into[k] = v
    end
  end
end

local function build_capabilities()
  local caps = {
    textDocumentSync = { openClose = true, change = 2 },
    positionEncoding = encoding,
  }
  if handlers["textDocument/didSave"] then caps.textDocumentSync.save = true end
  if handlers["workspace/didChangeWorkspaceFolders"] then
    caps.workspace = { workspaceFolders = { supported = true, changeNotifications = true } }
  end
  for method, entry in pairs(capability_keys) do
    if handlers[method] then
      caps[entry[1]] = type(entry[2]) == "table" and {} or entry[2]
    end
  end
  merge(caps, ulsp.capabilities)
  return caps
end

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

local function find_config()
  local env = os.getenv("ULSP_CONFIG")
  if env and env ~= "" then
    if exists(env) then return env end
    log.error("ULSP_CONFIG does not exist: " .. env)
    return nil
  end
  local xdg = os.getenv("XDG_CONFIG_HOME")
  if xdg and xdg ~= "" and exists(xdg .. "/ulsp/config.lua") then return xdg .. "/ulsp/config.lua" end
  local home = os.getenv("HOME")
  if home and home ~= "" and exists(home .. "/.config/ulsp/config.lua") then
    return home .. "/.config/ulsp/config.lua"
  end
  local appdata = os.getenv("APPDATA")
  if appdata and appdata ~= "" and exists(appdata .. "/ulsp/config.lua") then return appdata .. "/ulsp/config.lua" end
  log.info("no configuration found")
  return nil
end

local function run_config()
  local path = find_config()
  if not path then return end
  local dir = path:match("^(.*)[/\\][^/\\]*$") or "."
  if dir == "" then dir = "/" end
  -- Keep only absolute entries: the default "./?.lua" and "./?.so" would run files from the
  -- project the editor opened.
  local function absolute(p)
    local keep = {}
    for entry in p:gmatch("[^;]+") do
      if entry:sub(1, 1) == "/" or entry:match("^%a:[/\\]") then keep[#keep + 1] = entry end
    end
    return table.concat(keep, ";")
  end
  package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. absolute(package.path)
  package.cpath = absolute(package.cpath)
  local f = S.async(function()
    local chunk, err = loadfile(path)
    if not chunk then error(err, 0) end
    return chunk()
  end)
  pcall(f.await, f)
  local o = S.outcome(f)
  if o.kind == "error" then log.error("configuration failed: " .. o.trace) end
end

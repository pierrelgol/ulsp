-- Zig errors on save in a Bazel workspace (rules_zig), without a build.zig.
--
--   require("bazel_check")   -- from config.lua
--
-- On save of a .zig file it finds the rules_zig target that compiles the file by reading the BUILD
-- files, asks `bazel aquery` once for that target's zig command line, and reruns that command from
-- the execroot with -fno-emit-bin. That is semantic analysis only: a few seconds instead of a full
-- build and link. The errors become editor diagnostics. When the command cannot run (generated
-- files not built yet) it falls back to `bazel build <target>` once.
--
-- It never passes Bazel startup options or build flags: those would restart the Bazel server or
-- throw away its analysis cache, and slow down everyone's next build.
--
-- Also: a warning on .zig files that no zig_* rule lists in srcs, and a code action that opens the
-- BUILD rule that owns the file.
--
-- Zig analyzes lazily, so code the target never reaches (an uncalled generic function, a file no
-- root imports) reports nothing.

local bazel = os.getenv("BAZEL") or "bazel"
local log = ulsp.log

local checked_kinds = { zig_test = true, zig_binary = true, zig_shared_library = true }

local rules = {}        -- every zig_* rule: { kind, name, pkg, label, srcs, globs, labels, main, deps, build, line }
local by_label = {}
local filegroups = {}   -- label -> { workspace-relative path = true }
local build_texts = {}  -- package -> text of its BUILD file
local scanned = false
local execroot
local argv_cache = {}   -- label -> zig argv
local built = {}        -- label -> true once `bazel build` ran this session
local reported = {}     -- label -> { path = true } files that got diagnostics from that target
local last_target = {}  -- path -> label

local function root() return ulsp.root end

local function exists(path) return ulsp.fs.stat(path) ~= nil end

-- ---------------------------------------------------------------------------------------------
-- BUILD files
-- ---------------------------------------------------------------------------------------------

local function strings(text)
  local out = {}
  for s in (text or ""):gmatch('"([^"]*)"') do out[#out + 1] = s end
  return out
end

-- The text of `key = ...` up to the next `key =` of the same call.
local function attribute(block, key)
  local start = block:find("[%s,(]" .. key .. "%s*=")
  if not start then return nil end
  local rest = block:sub(start + 1):gsub("^[%w_]+%s*=%s*", "")
  local stop = rest:find("\n%s*[%w_]+%s*=") or #rest
  return rest:sub(1, stop)
end

local function label_of(dep, pkg)
  if dep:sub(1, 1) == "@" then return nil end
  if dep:sub(1, 1) == ":" then return pkg .. ":" .. dep:sub(2) end
  local p, name = dep:match("^//([^:]*):(.+)$")
  if p then return p .. ":" .. name end
  p = dep:match("^//(.+)$")
  if p then return p .. ":" .. p:match("([^/]+)$") end
  return pkg .. ":" .. dep
end

local function read_filegroups(pkg, text)
  for block in text:gmatch("filegroup%s*(%b())") do
    local name = attribute(block, "name")
    name = name and strings(name)[1]
    if name then
      local files = {}
      for _, src in ipairs(strings(attribute(block, "srcs"))) do
        if not src:match("^[:/@]") then files[pkg == "" and src or pkg .. "/" .. src] = true end
      end
      filegroups[pkg .. ":" .. name] = files
    end
  end
end

local function read_build(pkg, path, text)
  build_texts[pkg] = text
  read_filegroups(pkg, text)
  local position = 1
  while true do
    local s, e, kind = text:find("\n?(zig_[%w_]+)%s*%(", position)
    if not s then break end
    local block = text:match("^%b()", e)
    if not block then break end
    position = e + #block
    local name = attribute(block, "name")
    name = name and strings(name)[1]
    if name and kind ~= "zig_options" then
      local rule = { kind = kind, name = name, pkg = pkg, label = pkg .. ":" .. name, build = path,
        srcs = {}, globs = {}, labels = {}, deps = {}, dep_patterns = {}, line = select(2, text:sub(1, s):gsub("\n", "")) }
      local main = attribute(block, "main")
      rule.main = main and strings(main)[1]
      local srcs = attribute(block, "srcs") or ""
      for glob in srcs:gmatch("glob%s*(%b())") do
        for _, pattern in ipairs(strings(glob:match("%b[]"))) do rule.globs[#rule.globs + 1] = pattern end
      end
      for _, src in ipairs(strings((srcs:gsub("glob%s*%b()", "")))) do
        -- A label in srcs is usually a filegroup of .zig files from another package.
        if src:match("^[:/]") then
          rule.labels[#rule.labels + 1] = label_of(src, pkg)
        else
          rule.srcs[src] = true
        end
      end
      if rule.main then rule.srcs[rule.main] = true end
      for _, dep in ipairs(strings(attribute(block, "deps"))) do
        local label = label_of(dep, pkg)
        if label and label:find("{}", 1, true) then
          -- `"//platforms/{}".format(runtime)` in a comprehension: `{}` matches one path segment.
          local escaped = label:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
          rule.dep_patterns[#rule.dep_patterns + 1] = "^" .. escaped:gsub("{}", "[^/:]+") .. "$"
        elseif label then
          rule.deps[#rule.deps + 1] = label
        end
      end
      rules[#rules + 1] = rule
      by_label[rule.label] = rule
    end
  end
end

local function scan(dir, pkg)
  local ok, entries = pcall(ulsp.fs.list, dir)
  if not ok then return end
  for _, entry in ipairs(entries) do
    local name = entry.name
    if entry.kind == "directory" then
      if name:sub(1, 1) ~= "." and not name:match("^bazel%-") and name ~= "zig-out" then
        scan(dir .. "/" .. name, pkg == "" and name or pkg .. "/" .. name)
      end
    elseif name == "BUILD.bazel" or name == "BUILD" then
      local read_ok, text = pcall(ulsp.fs.read, dir .. "/" .. name)
      if read_ok then read_build(pkg, dir .. "/" .. name, text) end
    end
  end
end

-- One scan at a time: `initialized` and the first didOpen arrive together.
local scanning

local function rescan()
  if scanning then return scanning:await() end
  scanning = ulsp.async(function()
    rules, by_label, argv_cache, filegroups, build_texts = {}, {}, {}, {}, {}
    scan(root(), "")
    scanned = true
  end)
  local ok, err = pcall(scanning.await, scanning)
  scanning = nil
  if not ok then error(err, 0) end
end

-- `**` matches any number of directories, `*` anything but `/`.
local function glob_match(pattern, path)
  local function seg(p, s)
    local lua = "^" .. p:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", "[^/]*") .. "$"
    return s:match(lua) ~= nil
  end
  local function go(ps, i, ss, j)
    if i > #ps then return j > #ss end
    if ps[i] == "**" then
      for k = j, #ss + 1 do
        if go(ps, i + 1, ss, k) then return true end
      end
      return false
    end
    return j <= #ss and seg(ps[i], ss[j]) and go(ps, i + 1, ss, j + 1)
  end
  local ps, ss = {}, {}
  for p in pattern:gmatch("[^/]+") do ps[#ps + 1] = p end
  for s in path:gmatch("[^/]+") do ss[#ss + 1] = s end
  return go(ps, 1, ss, 1)
end

-- The package of a workspace-relative path: its nearest directory with a BUILD file.
local function package_of(rel)
  local dir = rel:match("^(.*)/[^/]*$") or ""
  while true do
    local base = root() .. (dir == "" and "" or "/" .. dir)
    if exists(base .. "/BUILD.bazel") or exists(base .. "/BUILD") then return dir end
    if dir == "" then return nil end
    dir = dir:match("^(.*)/[^/]*$") or ""
  end
end

local function owners(rel)
  local pkg = package_of(rel)
  if not pkg then return {}, nil end
  local inside = pkg == "" and rel or rel:sub(#pkg + 2)
  local found = {}
  for _, rule in ipairs(rules) do
    local owns = false
    if rule.pkg == pkg then
      owns = rule.srcs[inside]
      for _, pattern in ipairs(rule.globs) do owns = owns or glob_match(pattern, inside) end
    end
    for _, label in ipairs(rule.labels) do
      owns = owns or (filegroups[label] and filegroups[label][rel])
    end
    if owns then found[#found + 1] = rule end
  end
  return found, pkg
end

-- The target to compile for a file: a test or binary that owns it, else the nearest ones that
-- depend on a rule that owns it, following deps backwards. Among equally near ones: same package
-- first, tests first, then the one whose main is the file.
local function target_for(rel, owned, pkg)
  local dependents = {}
  local function depends(label, rule)
    local list = dependents[label] or {}
    dependents[label] = list
    list[#list + 1] = rule
  end
  for _, rule in ipairs(rules) do
    for _, dep in ipairs(rule.deps) do depends(dep, rule) end
    for _, pattern in ipairs(rule.dep_patterns) do
      for _, other in ipairs(rules) do
        if other.label:match(pattern) then depends(other.label, rule) end
      end
    end
  end
  local candidates = {}
  local seen = {}
  local level = owned
  for _, rule in ipairs(owned) do seen[rule.label] = true end
  while #level > 0 and #candidates == 0 do
    local next_level = {}
    for _, rule in ipairs(level) do
      if checked_kinds[rule.kind] then candidates[#candidates + 1] = rule end
      for _, dependent in ipairs(dependents[rule.label] or {}) do
        if not seen[dependent.label] then
          seen[dependent.label] = true
          next_level[#next_level + 1] = dependent
        end
      end
    end
    level = next_level
  end
  local function score(rule)
    local s = 0
    if rule.pkg == pkg then s = s + 8 end
    if rule.kind == "zig_test" then s = s + 4 end
    if rule.main and (rule.pkg == "" and rule.main or rule.pkg .. "/" .. rule.main) == rel then s = s + 2 end
    if rule.name == "test" or rule.name == (pkg or ""):match("([^/]*)$") then s = s + 1 end
    return s
  end
  table.sort(candidates, function(a, b)
    local sa, sb = score(a), score(b)
    if sa ~= sb then return sa > sb end
    return a.label < b.label
  end)
  return candidates[1]
end

-- ---------------------------------------------------------------------------------------------
-- Bazel and zig
-- ---------------------------------------------------------------------------------------------

-- Bazel calls hold the server lock: one at a time.
local bazel_busy = false

local function run_bazel(args)
  while bazel_busy do ulsp.sleep(100) end
  bazel_busy = true
  local cmd = { bazel }
  for _, a in ipairs(args) do cmd[#cmd + 1] = a end
  local ok, result = pcall(ulsp.process.run, { cmd = cmd, cwd = root() })
  bazel_busy = false
  if not ok then error(result, 0) end
  return result
end

-- Bazel rebuilds the execroot's external/ links for every command, keeping only the repositories
-- that command needs, so external paths point into output_base/external, which keeps them all.
local output_base

local function get_execroot()
  if execroot then return execroot end
  local out = run_bazel({ "info", "execution_root", "output_base" })
  if out.code == 0 then
    execroot = out.stdout:match("execution_root: ([^\n]+)")
    output_base = out.stdout:match("output_base: ([^\n]+)")
  end
  return execroot
end

local function get_argv(label)
  if argv_cache[label] then return argv_cache[label] end
  local out = run_bazel({ "aquery", 'mnemonic("ZigBuild.*", //' .. label .. ")", "--output=jsonproto", "--include_artifacts=false" })
  if out.code ~= 0 then
    log.warn("bazel_check: aquery //" .. label .. " failed: " .. out.stderr:sub(-500))
    return nil
  end
  local ok, data = pcall(ulsp.json.decode, out.stdout)
  if not ok or type(data) ~= "table" or type(data.actions) ~= "table" then return nil end
  for _, action in ipairs(data.actions) do
    local args = action.arguments
    if action.mnemonic ~= "ZigBuildDocs" and type(args) == "table" and #args > 1 and tostring(args[1]):match("zig$") then
      local argv = {}
      for _, a in ipairs(args) do
        if a:sub(1, 1) == "@" then
          log.warn("bazel_check: //" .. label .. " uses a params file, not supported")
          return nil
        end
        if not a:match("^%-femit%-") then
          if output_base then a = a:gsub("^external/", output_base .. "/external/"):gsub("=external/", "=" .. output_base .. "/external/") end
          argv[#argv + 1] = a
        end
      end
      table.insert(argv, 3, "-fno-emit-bin")
      argv_cache[label] = argv
      return argv
    end
  end
  return nil
end

-- `path:line:col: error: message` lines; notes are folded into the error before them.
local function parse(stderr)
  local out = {}
  local last
  for line in (stderr .. "\n"):gmatch("([^\n]*)\n") do
    local file, l, c, kind, message = line:match("^([^:%s][^:]*%.zig):(%d+):(%d+): (%a+): (.*)$")
    if file then
      if kind == "note" and last then
        last.message = last.message .. "\nnote: " .. message
        last.related[#last.related + 1] = { file = file, line = tonumber(l), col = tonumber(c), message = message }
      else
        last = { file = file, line = tonumber(l), col = tonumber(c), kind = kind, message = message, related = {} }
        out[#out + 1] = last
      end
    end
  end
  return out
end

local function absolute(file)
  if file:sub(1, 1) == "/" then return file end
  if file:match("^external/") then
    return output_base and output_base .. "/" .. file or nil
  elseif file:match("^bazel%-out/") then
    return execroot and execroot .. "/" .. file or nil
  end
  return root() .. "/" .. file
end

local function publish(label, errors)
  local per_file = {}
  for _, e in ipairs(errors) do
    local path = absolute(e.file)
    if path then
      local list = per_file[path] or ulsp.json.array({})
      per_file[path] = list
      local related = ulsp.json.array({})
      for _, r in ipairs(e.related) do
        local rpath = absolute(r.file)
        if rpath then
          related[#related + 1] = { message = r.message, location = { uri = ulsp.uri.from_path(rpath),
            range = { start = { line = r.line - 1, character = r.col - 1 }, ["end"] = { line = r.line - 1, character = r.col - 1 } } } }
        end
      end
      local at = { line = e.line - 1, character = e.col - 1 }
      list[#list + 1] = {
        range = { start = at, ["end"] = { line = at.line, character = at.character + 1 } },
        severity = e.kind == "error" and 1 or 2, source = "zig //" .. label, message = e.message,
        relatedInformation = #related > 0 and related or nil,
      }
    end
  end
  for path in pairs(reported[label] or {}) do
    if not per_file[path] then
      ulsp.rpc.notify("textDocument/publishDiagnostics", { uri = ulsp.uri.from_path(path), diagnostics = ulsp.json.array({}) })
    end
  end
  reported[label] = {}
  for path, list in pairs(per_file) do
    reported[label][path] = true
    ulsp.rpc.notify("textDocument/publishDiagnostics", { uri = ulsp.uri.from_path(path), diagnostics = list })
  end
end

local function progress(title)
  local token = "bazel_check:" .. title
  local ok = pcall(ulsp.rpc.request, "window/workDoneProgress/create", { token = token })
  if not ok then return function() end end
  ulsp.rpc.notify("$/progress", { token = token, value = { kind = "begin", title = title } })
  return function(message)
    ulsp.rpc.notify("$/progress", { token = token, value = { kind = "end", message = message } })
  end
end

local function check(label)
  local done = progress("zig check //" .. label)
  -- Ends the progress even when a newer save cancels this check.
  local _ <close> = setmetatable({}, { __close = function() done() end })
  local root_dir = get_execroot()
  local argv = root_dir and get_argv(label)
  local errors, ran = {}, false
  if argv then
    local out = ulsp.process.run({ cmd = argv, cwd = root_dir })
    errors = parse(out.stderr)
    ran = out.code == 0 or #errors > 0
    -- A missing external or generated file means inputs are not fetched or built yet, not a bug.
    for _, e in ipairs(errors) do
      if e.message:find("FileNotFound", 1, true) and (e.file:match("^external/") or e.file:match("^bazel%-out/")) then
        ran = false
      end
    end
    if not ran then log.info("bazel_check: zig could not run for //" .. label .. ": " .. out.stderr:sub(1, 300)) end
  else
    log.info("bazel_check: no zig command for //" .. label)
  end
  if not ran and not built[label] then
    -- Generated inputs missing, or no aquery: let Bazel build it once and report its errors.
    built[label] = true
    log.info("bazel_check: bazel build //" .. label)
    local out = run_bazel({ "build", "//" .. label })
    errors = parse(out.stderr)
    ran = out.code == 0 or #errors > 0
    if not ran then log.warn("bazel_check: bazel build //" .. label .. " failed:\n" .. out.stderr:sub(-1500)) end
  end
  -- Nothing ran: keep the diagnostics as they are rather than claim the file is clean.
  if ran then publish(label, errors) end
  done(not ran and "check unavailable, see log" or #errors == 0 and "no errors" or (#errors .. " errors"))
  done = function() end
end

-- One check per target at a time: a save during a check cancels it and starts again.
local running = {}

local function schedule(label)
  local previous = running[label]
  if previous then previous:cancel() end
  local f = ulsp.async(check, label)
  running[label] = f
  ulsp.async(function()
    local ok, err = pcall(f.await, f)
    if not ok and err ~= ulsp.canceled then log.error("bazel_check: //" .. label .. ": " .. tostring(err)) end
    if running[label] == f then running[label] = nil end
  end)
end

-- ---------------------------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------------------------

local function relative(path)
  local r = root()
  if r and path:sub(1, #r + 1) == r .. "/" then return path:sub(#r + 2) end
end

-- Decided now, not in `initialized`: the editor sends didOpen right after it.
local function readable(path)
  local f = io.open(path, "r")
  if f then f:close() end
  return f ~= nil
end
local enabled = root() ~= nil and (readable(root() .. "/MODULE.bazel") or readable(root() .. "/WORKSPACE")
  or readable(root() .. "/WORKSPACE.bazel"))

local function not_in_srcs(uri, rel)
  ulsp.rpc.notify("textDocument/publishDiagnostics", { uri = uri, diagnostics = ulsp.json.array({ {
    range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } },
    severity = 2, source = "bazel",
    message = rel .. " is not in the srcs of any zig_* rule; Bazel will not compile it",
  } }) })
end

local function on_zig_file(p, why)
  if not enabled then return end
  local uri = p.textDocument.uri
  local path = ulsp.uri.to_path(uri)
  if not path or not path:match("%.zig$") then return end
  local rel = relative(path)
  if not rel then return end
  if not scanned then rescan() end
  local owned, pkg = owners(rel)
  if #owned == 0 then
    -- Only when the BUILD file does not mention the file at all (exports_files, filegroup,
    -- genrule... use it some other way).
    local inside = pkg and (pkg == "" and rel or rel:sub(#pkg + 2))
    if pkg and rel:match("[^/]+$") ~= "build.zig" and not (build_texts[pkg] or ""):find('"' .. inside .. '"', 1, true) then
      not_in_srcs(uri, rel)
    end
    return
  end
  local target = target_for(rel, owned, pkg)
  if not target then return end
  last_target[path] = target.label
  if why == "open" and reported[target.label] then return end
  schedule(target.label)
end

ulsp.add("initialized", function()
  if enabled and not scanned then
    rescan()
    log.info(string.format("bazel_check: %d zig rules", #rules))
  end
end)

ulsp.add("textDocument/didOpen", function(p) on_zig_file(p, "open") end)

ulsp.add("textDocument/didSave", function(p)
  local path = ulsp.uri.to_path(p.textDocument.uri) or ""
  local name = path:match("([^/]+)$") or ""
  if enabled and (name == "BUILD.bazel" or name == "BUILD" or name == "MODULE.bazel" or name:match("%.bzl$") or name == ".bazelrc") then
    rescan()
    built = {}
    return
  end
  on_zig_file(p, "save")
end)

-- "Open BUILD rule": a code action whose command asks the editor to show the BUILD file.
ulsp.capabilities.executeCommandProvider = { commands = { "bazel_check.open_build" } }

ulsp.on("textDocument/codeAction", function(p)
  local actions = ulsp.json.array({})
  if not enabled then return actions end
  local path = ulsp.uri.to_path(p.textDocument.uri)
  local rel = path and relative(path)
  if not rel then return actions end
  if not scanned then rescan() end
  local owned = owners(rel)
  local listed = {}
  for _, rule in ipairs(owned) do
    listed[rule.label] = true
    actions[#actions + 1] = {
      title = "Open BUILD rule //" .. rule.label .. " (" .. rule.kind .. ")",
      command = { title = "Open BUILD rule", command = "bazel_check.open_build", arguments = { rule.build, rule.line } },
    }
  end
  local label = last_target[path]
  if label and by_label[label] and not listed[label] then
    local rule = by_label[label]
    actions[#actions + 1] = {
      title = "Open checked target //" .. label,
      command = { title = "Open BUILD rule", command = "bazel_check.open_build", arguments = { rule.build, rule.line } },
    }
  end
  return actions
end)

ulsp.on("workspace/executeCommand", function(p)
  if p.command ~= "bazel_check.open_build" then error({ code = -32601, message = "unknown command" }, 0) end
  local file, line = p.arguments[1], p.arguments[2]
  local at = { line = line, character = 0 }
  ulsp.rpc.request("window/showDocument", { uri = ulsp.uri.from_path(file), takeFocus = true,
    selection = { start = at, ["end"] = at } })
  return ulsp.null
end)

log.info("bazel_check: loaded")

return { rescan = rescan, owners = owners, target_for = target_for, get_argv = get_argv,
  rules = function() return rules end }

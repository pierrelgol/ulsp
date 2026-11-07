-- Naive Zig completion, no build.zig and no zls needed.
--
--   ULSP_CONFIG=examples/zig.lua ulsp
--
-- At startup it walks the workspace, parses every .zig file with tree-sitter and records the
-- declarations of each container (file, struct, enum, union, error set): consts, vars, fns, fields,
-- enum members and error names. Completion after `a.b.c.` resolves the chain the way a human
-- skimming the code would: imports, aliases (`pub const T = x.T`), `@This()`, type annotations,
-- struct initializers and function return types. When that fails, it offers the members of the
-- container whose name is the most similar to the last word before the dot.
--
-- Module names in `@import("name")` come from `zig_library(...)` rules in BUILD.bazel files, then
-- from guesses (`name/name.zig`, `name.zig`, any file called `name.zig`). `std` is read from the
-- Zig lib directory: $ZIG_LIB_DIR, or `lib_dir` printed by `zig env`. Std files are only parsed
-- when a chain walks into them.

local parser_dir = os.getenv("ULSP_PARSER_DIR") or (os.getenv("HOME") .. "/.config/ulsp/runtime/parsers")
local zig = select(2, pcall(ulsp.ts.load, "zig", parser_dir .. "/libzig.so"))
if type(zig) ~= "userdata" then zig = ulsp.ts.load("zig", parser_dir .. "/libzig.dylib") end

ulsp.capabilities.completionProvider = { triggerCharacters = { ".", "@" } }

local max_items = 200
local skip_dirs = { ["zig-out"] = true, ["zig-cache"] = true, ["node_modules"] = true }

-- LSP CompletionItemKind
local K = {
  method = 2, fn = 3, field = 5, variable = 6, class = 7, module = 9, keyword = 14,
  enum = 13, enum_member = 20, constant = 21, struct = 22, type_param = 25,
}

-- ---------------------------------------------------------------------------------------------
-- Index
-- ---------------------------------------------------------------------------------------------

local files = {}          -- path -> file container, or false while it is being read
local file_versions = {}  -- path -> version of the open document it was indexed from
local named = {}          -- path -> named containers of that file (for the similarity search)
local workspace = {}      -- every .zig path found under the root
local workspace_set = {}
local modules = {}        -- import name -> path
local zig_lib             -- Zig lib directory, for `std`

local container_types = {
  struct_declaration = "struct", enum_declaration = "enum", union_declaration = "union",
  opaque_declaration = "opaque", error_set_declaration = "error",
}

-- State of the file being indexed: its path, its text and its list of named containers.
local cx

local function new_container(kind, name, parent, s, e)
  local c = { kind = kind, name = name, file = cx.path, parent = parent, members = {}, order = {}, children = {}, s = s, e = e }
  if parent and parent.children then parent.children[#parent.children + 1] = c end
  if name then cx.named[#cx.named + 1] = c end
  return c
end

local function add(c, d)
  d.owner = c
  d.file = d.file or cx.path
  if not c.members[d.name] then c.order[#c.order + 1] = d end
  c.members[d.name] = d
end

local function line_of(node)
  return node:start_point().row
end

local function squash(s, limit)
  s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if #s > limit then s = s:sub(1, limit - 1) .. "…" end
  return s
end

local function has_token(node, token)
  for _, ch in ipairs(node:children()) do
    if ch:type() == token then return true end
  end
  return false
end

local function string_arg(node)
  local args = node:named_children()[2]
  local str = args and args:named_children()[1]
  local content = str and str:type() == "string" and str:named_children()[1]
  return content and content:text()
end

local index_container, expr_of

-- Turns a type or value expression into something `eval` can follow later, after the tree is gone.
function expr_of(n, scope, name)
  if not n then return nil end
  local t = n:type()
  if t == "identifier" then
    return { k = "id", name = n:text(), scope = scope }
  elseif t == "field_expression" then
    local object, member = n:field("object"), n:field("member")
    local base = object and expr_of(object, scope)
    return base and member and { k = "field", base = base, name = member:text() }
  elseif t == "call_expression" then
    local fn = expr_of(n:field("function"), scope)
    return fn and { k = "call", fn = fn }
  elseif t == "builtin_function" then
    local builtin = n:named_children()[1]:text()
    if builtin == "@import" then
      local path = string_arg(n)
      return path and { k = "import", name = path, from = cx.path }
    elseif builtin == "@This" then
      return { k = "this", scope = scope }
    end
  elseif container_types[t] then
    return { k = "container", c = index_container(n, container_types[t], name, scope) }
  elseif t == "struct_initializer" then
    local ty = expr_of(n:named_children()[1], scope)
    return ty and { k = "inst", ty = ty }
  elseif t == "error_union_type" then
    return expr_of(n:field("ok"), scope)
  elseif t == "try_expression" or t == "pointer_type" or t == "nullable_type" or t == "parenthesized_expression"
    or t == "comptime_expression" then
    local inner = n:named_children()
    return expr_of(inner[#inner], scope)
  end
  return nil
end

-- `fn Foo(comptime T: type) type { return struct { ... }; }`: the returned type.
local function returned_type(body, scope, name)
  for _, statement in ipairs(body:named_children()) do
    local ret = statement:type() == "expression_statement" and statement:named_children()[1] or statement
    if ret:type() == "return_expression" then
      return expr_of(ret:named_children()[1], scope, name)
    end
  end
end

local function declaration(n, c, doc)
  local t = n:type()
  local s, e = n:byte_range()
  local d
  if t == "variable_declaration" then
    local parts = n:named_children()
    local name, ty = parts[1], n:field("type")
    local value = parts[#parts]
    if not name or name:type() ~= "identifier" then return end
    if value == name or (ty and value == ty) then value = nil end
    d = { name = name:text(), kind = has_token(n, "var") and "var" or "const", pub = has_token(n, "pub"),
      type = expr_of(ty, c) }
    d.value = expr_of(value, c, d.name)
    if d.value and d.value.k == "container" then d.container = d.value.c end
    if d.value and d.value.k == "import" then d.import = true end
    d.sig = squash(cx.text:sub(s + 1, e):match("^[^\n]*"), 100)
  elseif t == "function_declaration" then
    local name, body, ret = n:field("name"), n:field("body"), n:field("type")
    if not name then return end
    local params = n:named_children()[2]
    local first = params and params:type() == "parameters" and params:named_children()[1]
    local first_name = first and first:field("name")
    d = { name = name:text(), kind = "fn", pub = has_token(n, "pub"), ret = expr_of(ret, c),
      method = first_name and first_name:text() == "self" or false }
    if body and ret and ret:text() == "type" then d.ret_type = returned_type(body, c, d.name) end
    local sig_end = body and select(1, body:byte_range()) or e
    d.sig = squash(cx.text:sub(s + 1, sig_end), 160)
  elseif t == "container_field" then
    local name = n:field("name")
    if not name or not name:text():match("^[%a_][%w_]*$") then return end
    local kind = (c.kind == "enum" and "enum_field") or "field"
    d = { name = name:text(), kind = kind, pub = true, type = expr_of(n:field("type"), c),
      sig = squash(cx.text:sub(s + 1, e), 100) }
  elseif t == "identifier" and c.kind == "error" then
    d = { name = n:text(), kind = "error", pub = true, sig = "error." .. n:text() }
  else
    return
  end
  d.line = line_of(n)
  if #doc > 0 then d.doc = table.concat(doc, "\n") end
  add(c, d)
end

-- Declarations caught in an ERROR node (the code being typed) still count as members.
local function index_members(node, c, doc)
  for _, ch in ipairs(node:named_children()) do
    local t = ch:type()
    if t == "comment" then
      local text = ch:text()
      if text:sub(1, 3) == "///" and text:sub(4, 4) ~= "/" then
        doc[#doc + 1] = text:sub(4):gsub("^ ", "")
      else
        doc = {}
      end
    elseif t == "ERROR" then
      doc = index_members(ch, c, doc)
    else
      declaration(ch, c, doc)
      doc = {}
    end
  end
  return doc
end

function index_container(node, kind, name, parent)
  local s, e = node:byte_range()
  local c = new_container(kind, name, parent, s, e)
  index_members(node, c, {})
  return c
end

local function index_tree(path, root, text)
  local previous = cx
  cx = { path = path, text = text, named = {} }
  local name = path:match("([^/]+)%.zig$")
  local ok, c = pcall(index_container, root, "file", name, nil)
  local list = cx.named
  cx = previous
  if not ok then
    ulsp.log.warn("zig: cannot index " .. path .. ": " .. tostring(c))
    return nil
  end
  files[path] = c
  named[path] = list
  return c
end

local function index_text(path, text)
  return index_tree(path, ulsp.ts.parse(zig, text):root(), text)
end

-- An open document is indexed from its live tree, again whenever its version changes.
local function index_open(doc, path)
  local version = doc:version()
  if file_versions[path] ~= version or not files[path] then
    local tree = ulsp.ts.tree(doc, zig)
    if tree and index_tree(path, tree:root(), doc:text()) then file_versions[path] = version end
  end
  return files[path]
end

local function get_file(path)
  local c = files[path]
  if c ~= nil then return c or nil end
  local doc = ulsp.docs.get(ulsp.uri.from_path(path))
  if doc then return index_open(doc, path) end
  files[path] = false
  local ok, text = pcall(ulsp.fs.read, path)
  if not ok or type(text) ~= "string" then
    files[path] = nil
    return nil
  end
  return index_text(path, text)
end

-- ---------------------------------------------------------------------------------------------
-- Module names
-- ---------------------------------------------------------------------------------------------

local function normalize(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      parts[#parts] = nil
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return "/" .. table.concat(parts, "/")
end

local function read_bazel(dir, text)
  for block in text:gmatch("zig_library%s*(%b())") do
    local name = block:match('[%s,(]name%s*=%s*"([^"]+)"')
    local import_name = block:match('import_name%s*=%s*"([^"]+)"')
    local main = block:match('[%s,(]main%s*=%s*"([^"]+)"')
    local key = import_name or name
    if key and main and not modules[key] then modules[key] = normalize(dir .. "/" .. main) end
  end
end

local function import_path(name, from)
  if name:match("%.zig$") then
    return normalize((from:match("^(.*)/[^/]*$") or ".") .. "/" .. name)
  elseif name == "std" then
    return zig_lib and zig_lib .. "/std/std.zig"
  elseif name == "builtin" or name == "root" or name:match("%.zon$") then
    return nil
  elseif modules[name] then
    return modules[name]
  end
  local last = name:match("([^/]+)$")
  local root = ulsp.root or ""
  for _, candidate in ipairs({
    root .. "/" .. name .. "/" .. last .. ".zig", root .. "/" .. name .. ".zig",
    root .. "/" .. name .. "/root.zig", root .. "/" .. name .. "/main.zig",
  }) do
    if workspace_set[candidate] then return candidate end
  end
  local best
  for _, path in ipairs(workspace) do
    if path:match("([^/]+)%.zig$") == last and (not best or #path < #best) then best = path end
  end
  return best
end

-- ---------------------------------------------------------------------------------------------
-- Resolution
-- ---------------------------------------------------------------------------------------------

local function lookup(scope, name)
  while scope do
    local d = scope.members[name]
    if d then return d end
    scope = scope.parent
  end
end

local eval

local function resolve(e, depth)
  if e.k == "decl" then return e.d end
  if e.k == "id" then return lookup(e.scope, e.name) end
  if e.k == "field" then
    local v = eval(e.base, depth)
    return v and v.c.members[e.name]
  end
end

local function eval_decl(d, depth)
  if d.kind == "fn" then return nil end
  if d.container then return { c = d.container } end
  if d.type then
    local v = eval(d.type, depth)
    if v then return { c = v.c, inst = true } end
  end
  return eval(d.value, depth)
end

-- A value is { c = container, inst = true when it is an instance rather than the type itself }.
function eval(e, depth)
  depth = (depth or 0) + 1
  if not e or depth > 32 then return nil end
  if e.k == "container" then
    return { c = e.c }
  elseif e.k == "this" then
    local scope = e.scope
    while scope and scope.kind == "locals" do scope = scope.parent end
    return scope and { c = scope }
  elseif e.k == "import" then
    local path = import_path(e.name, e.from)
    local c = path and get_file(path)
    return c and { c = c }
  elseif e.k == "inst" then
    local v = eval(e.ty, depth)
    return v and { c = v.c, inst = true }
  elseif e.k == "call" then
    local d = resolve(e.fn, depth)
    if d and d.kind == "fn" then
      if d.ret_type then return eval(d.ret_type, depth) end
      local v = eval(d.ret, depth)
      return v and { c = v.c, inst = true }
    end
  else
    local d = resolve(e, depth)
    return d and eval_decl(d, depth)
  end
end

-- "most similar": Dice coefficient of character bigrams, ignoring case and underscores.
local function bigrams(s)
  local set, n = {}, 0
  for i = 1, #s - 1 do
    local b = s:sub(i, i + 1)
    set[b] = (set[b] or 0) + 1
    n = n + 1
  end
  return set, n
end

local function similarity(a, b)
  a, b = a:lower():gsub("_", ""), b:lower():gsub("_", "")
  if a == b then return 1 end
  if #a < 2 or #b < 2 then return 0 end
  local sa, na = bigrams(a)
  local sb, nb = bigrams(b)
  local common = 0
  for k, count in pairs(sa) do common = common + math.min(count, sb[k] or 0) end
  local score = 2 * common / (na + nb)
  if a:find(b, 1, true) or b:find(a, 1, true) then score = math.max(score, 0.7) end
  return score
end

local function similar_containers(word)
  local best, best_score = {}, 0.5
  for _, list in pairs(named) do
    for _, c in ipairs(list) do
      if #c.order > 0 then
        local score = similarity(word, c.name)
        if score > best_score + 1e-9 then
          best, best_score = { c }, score
        elseif math.abs(score - best_score) < 1e-9 and #best < 3 then
          best[#best + 1] = c
        end
      end
    end
  end
  return best
end

-- ---------------------------------------------------------------------------------------------
-- What is before the cursor
-- ---------------------------------------------------------------------------------------------

local function skip_space(s, i, pattern)
  while i > 0 and s:sub(i, i):match(pattern or "%s") do i = i - 1 end
  return i
end

-- Reads `a.b(x).c` backwards from the end of `s` (the text before the final dot).
-- Returns a list of segments { name, call, args, builtin }, "literal" for `.x`, or nil.
local function chain_before(s)
  local segments = {}
  local i = skip_space(s, #s)
  while true do
    local call, args = false, nil
    if s:sub(i, i) == ")" then
      local close, depth = i, 0
      repeat
        local ch = s:sub(i, i)
        if ch == ")" then depth = depth + 1 elseif ch == "(" then depth = depth - 1 end
        i = i - 1
      until depth == 0 or i < 1
      if depth ~= 0 then return nil end
      call, args = true, s:sub(i + 2, close - 1)
    end
    local j = i
    while j > 0 and s:sub(j, j):match("[%w_]") do j = j - 1 end
    local word = s:sub(j + 1, i)
    if word == "" then
      if #segments == 0 and not call then return "literal" end
      return nil
    end
    if word:match("^%d") then return nil end
    local builtin = s:sub(j, j) == "@"
    if builtin then j = j - 1 end
    table.insert(segments, 1, { name = word, call = call, args = args, builtin = builtin })
    -- `foo\n    .bar` continues a chain, `foo.\n    bar` does not (that is a line being typed).
    i = skip_space(s, j, "[ \t]")
    if builtin or s:sub(i, i) ~= "." then return segments end
    i = skip_space(s, i - 1)
  end
end

local function innermost(c, offset)
  for _, child in ipairs(c.children) do
    if child.s and child.s <= offset and offset < child.e then return innermost(child, offset) end
  end
  return c
end

-- Parameters, local declarations and payloads before `offset` in the enclosing function, as a
-- scope whose parent is the enclosing container. The whole function body is searched, not just the
-- blocks around the cursor: the line being typed is usually a syntax error, and tree-sitter often
-- folds the statements around it into an ERROR node.
local max_local_nodes = 20000

local function locals_at(root, offset, container, path, text)
  local scope = { kind = "locals", members = {}, order = {}, parent = container }
  local top, error_node
  local node = root:descendant_for_range(math.max(offset - 1, 0), offset)
  while node and not container_types[node:type()] do
    local t = node:type()
    if t == "function_declaration" then top = node end
    if t == "ERROR" and not error_node then error_node = node end
    node = node:parent()
  end
  top = top or error_node
  if not top then return scope end

  local previous = cx
  cx = { path = path, text = text, named = {} }
  local budget = max_local_nodes
  local function visit(n)
    budget = budget - 1
    if budget < 0 then return end
    local t = n:type()
    local s, e = n:byte_range()
    if s >= offset or container_types[t] then return end
    if t == "variable_declaration" then
      if e <= offset then pcall(declaration, n, scope, {}) end
      return
    elseif t == "parameter" then
      local name = n:field("name")
      if name then
        add(scope, { name = name:text(), kind = "param", type = expr_of(n:field("type"), scope),
          sig = squash(n:text(), 80), line = line_of(n) })
      end
      return
    elseif t == "payload" then
      for _, name in ipairs(n:named_children()) do
        if name:type() == "identifier" then
          add(scope, { name = name:text(), kind = "param", sig = "|" .. name:text() .. "|", line = line_of(name) })
        end
      end
      return
    end
    for _, child in ipairs(n:named_children()) do visit(child) end
  end
  visit(top)
  cx = previous
  return scope
end

-- ---------------------------------------------------------------------------------------------
-- Completion items
-- ---------------------------------------------------------------------------------------------

-- Match class (0 prefix, 1 case-insensitive prefix, 2 substring, 3 subsequence) and a tie-breaker.
local function fuzzy(label, query)
  if label:sub(1, #query) == query then return 0, 0 end
  local l, q = label:lower(), query:lower()
  if l:sub(1, #q) == q then return 1, 0 end
  local at = l:find(q, 1, true)
  if at then return 2, at + #label end
  local j = 1
  for i = 1, #l do
    if l:sub(i, i) == q:sub(j, j) then
      j = j + 1
      if j > #q then return 3, #label end
    end
  end
end

local container_kinds = { struct = K.struct, enum = K.enum, union = K.struct, opaque = K.class, error = K.enum, file = K.module }

local function item_kind(d)
  if d.kind == "fn" then return d.method and K.method or K.fn end
  if d.kind == "field" then return K.field end
  if d.kind == "enum_field" or d.kind == "error" then return K.enum_member end
  if d.kind == "param" then return K.variable end
  if d.import then return K.module end
  if d.container then return container_kinds[d.container.kind] end
  if d.kind == "var" then return K.variable end
  return K.constant
end

local function relative(path)
  local root = ulsp.root
  if root and path:sub(1, #root + 1) == root .. "/" then return path:sub(#root + 2) end
  if zig_lib and path:sub(1, #zig_lib + 1) == zig_lib .. "/" then return "zig/" .. path:sub(#zig_lib + 2) end
  return path
end

local Items = {}
Items.__index = Items

local function new_items(query, range)
  return setmetatable({ query = query, range = range, list = {}, seen = {} }, Items)
end

-- Better matches first, then lower rank (0 is the nearest scope), then shorter labels.
function Items:add(label, kind, rank, detail, documentation)
  if self.seen[label] then return end
  local class, tie = fuzzy(label, self.query)
  if not class then return end
  self.seen[label] = true
  self.list[#self.list + 1] = {
    label = label, kind = kind, detail = detail, filterText = label,
    sortText = string.format("%d%d%04d%s", class, rank, math.min(tie, 9999), label),
    documentation = documentation and { kind = "markdown", value = documentation } or nil,
    textEdit = { range = self.range, newText = label },
  }
end

function Items:decl(d, rank, note)
  local where = d.file and (relative(d.file) .. ":" .. ((d.line or 0) + 1)) or nil
  local docs = {}
  if d.doc then docs[#docs + 1] = d.doc end
  if note then docs[#docs + 1] = note end
  if where then docs[#docs + 1] = "`" .. where .. "`" end
  self:add(d.name, item_kind(d), rank, d.sig, #docs > 0 and table.concat(docs, "\n\n") or nil)
end

function Items:members(c, inst, note, foreign)
  for _, d in ipairs(c.order) do
    if not foreign or d.pub then
      local rank = 2
      if inst then
        if d.kind == "field" or d.method then rank = 1 end
      elseif d.kind ~= "field" then
        rank = 1
      end
      self:decl(d, rank, note)
    end
  end
end

function Items:result()
  table.sort(self.list, function(a, b) return a.sortText < b.sortText end)
  local items = ulsp.json.array({})
  for i = 1, math.min(#self.list, max_items) do items[i] = self.list[i] end
  return { isIncomplete = true, items = items }
end

local keywords = {
  "addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm", "break", "callconv", "catch",
  "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error", "export", "extern", "fn",
  "for", "if", "inline", "linksection", "noalias", "noinline", "nosuspend", "opaque", "or", "orelse",
  "packed", "pub", "resume", "return", "struct", "suspend", "switch", "test", "threadlocal", "try", "union",
  "unreachable", "var", "volatile", "while", "null", "undefined", "true", "false",
}

local primitives = {
  "bool", "void", "noreturn", "type", "anyerror", "anyopaque", "comptime_int", "comptime_float",
  "isize", "usize", "c_int", "c_uint", "c_long", "c_ulong", "c_char", "f16", "f32", "f64", "f80", "f128",
  "i8", "i16", "i32", "i64", "i128", "u1", "u8", "u16", "u32", "u64", "u128",
}

local builtins = {
  "addrSpaceCast", "addWithOverflow", "alignCast", "alignOf", "as", "atomicLoad", "atomicRmw", "atomicStore",
  "bitCast", "bitOffsetOf", "bitReverse", "bitSizeOf", "branchHint", "breakpoint", "byteSwap", "call",
  "cDefine", "cImport", "cInclude", "clz", "cmpxchgStrong", "cmpxchgWeak", "compileError", "compileLog",
  "constCast", "ctz", "cUndef", "cVaArg", "cVaCopy", "cVaEnd", "cVaStart", "divExact", "divFloor",
  "divTrunc", "embedFile", "enumFromInt", "errorFromInt", "errorName", "errorReturnTrace", "errSetCast",
  "export", "extern", "field", "fieldParentPtr", "FieldType", "floatCast", "floatFromInt", "frameAddress",
  "hasDecl", "hasField", "import", "inComptime", "intCast", "intFromBool", "intFromEnum", "intFromError",
  "intFromFloat", "intFromPtr", "max", "memcpy", "memset", "memmove", "min", "mod", "mulAdd",
  "mulWithOverflow", "offsetOf", "panic", "popCount", "prefetch", "ptrCast", "ptrFromInt", "reduce", "rem",
  "returnAddress", "select", "setEvalBranchQuota", "setFloatMode", "setRuntimeSafety", "shlExact",
  "shlWithOverflow", "shrExact", "shuffle", "sizeOf", "splat", "src", "sqrt", "sin", "cos", "tan", "exp",
  "exp2", "log", "log2", "log10", "abs", "floor", "ceil", "trunc", "round", "subWithOverflow", "tagName",
  "This", "trap", "truncate", "Type", "typeInfo", "typeName", "TypeOf", "unionInit", "Vector", "volatileCast",
  "workGroupId", "workGroupSize", "workItemId",
}

-- Every declaration of every indexed file that passes `keep`, current file first.
local function each_decl(current, keep, fn)
  local function walk(c)
    for _, d in ipairs(c.order) do
      if keep(d) then fn(d, c.file == current) end
    end
    for _, child in ipairs(c.children) do walk(child) end
  end
  if files[current] then walk(files[current]) end
  for path, c in pairs(files) do
    if c and path ~= current then walk(c) end
  end
end

local function chain_expr(segments, scope, path)
  local first = segments[1]
  local e
  if first.builtin then
    if first.name == "import" then
      local name = first.args and first.args:match('"([^"]+)"')
      e = name and { k = "import", name = name, from = path }
    elseif first.name == "This" then
      e = { k = "this", scope = scope }
    end
  else
    local d = lookup(scope, first.name)
    e = d and { k = "decl", d = d } or { k = "id", name = first.name, scope = scope }
    if first.call then e = { k = "call", fn = e } end
  end
  for i = 2, #segments do
    if not e then break end
    e = { k = "field", base = e, name = segments[i].name }
    if segments[i].call then e = { k = "call", fn = e } end
  end
  return e
end

local function member_completion(items, segments, scope, path)
  local v = eval(chain_expr(segments, scope, path))
  if v then
    items:members(v.c, v.inst, nil, v.c.file ~= path)
    return
  end
  local word = segments[#segments].name
  for _, c in ipairs(similar_containers(word)) do
    items:members(c, true, "≈ `" .. c.name .. "` (guessed from `" .. word .. "`)", c.file ~= path)
  end
end

ulsp.on("textDocument/completion", function(p)
  local doc = ulsp.docs.get(p.textDocument.uri)
  if not doc then return { isIncomplete = false, items = ulsp.json.array({}) } end
  local path = ulsp.uri.to_path(doc:uri())
  local text = doc:text()
  local offset = doc:offset(p.position)
  local current = index_open(doc, path)
  if not current then return { isIncomplete = true, items = ulsp.json.array({}) } end

  local before = text:sub(1, offset)
  local query = before:match("[%w_]*$")
  local head = before:sub(1, #before - #query)
  local start = offset - #query
  local is_builtin = head:sub(-1) == "@"
  if is_builtin then start = start - 1 end
  local range = { start = doc:position(start), ["end"] = doc:position(offset) }
  local items = new_items(is_builtin and "@" .. query or query, range)

  if is_builtin then
    for _, name in ipairs(builtins) do items:add("@" .. name, K.fn, 1, "builtin") end
    return items:result()
  end

  local container = innermost(current, offset)
  local tree = ulsp.ts.tree(doc, zig)
  local scope = tree and locals_at(tree:root(), offset, container, path, text) or container

  if head:sub(-1) == "." then
    local segments = chain_before(head:sub(1, -2))
    if segments == "literal" then
      -- `.x`: enum members and fields, those of the annotated type (`x: T = .`) first, then the
      -- nearest ones.
      local kinds = { enum_field = true, field = true }
      local annotation = head:sub(1, -2):match(":%s*([%w_%.]+)%s*=%s*$")
      local typed = annotation and chain_before(annotation)
      local v = type(typed) == "table" and eval(chain_expr(typed, scope, path))
      if v then
        for _, d in ipairs(v.c.order) do
          if kinds[d.kind] then items:decl(d, 0) end
        end
      end
      each_decl(path, function(d) return kinds[d.kind] end, function(d, here)
        items:decl(d, here and 1 or 2)
      end)
    elseif segments and #segments == 1 and segments[1].name == "error" and not segments[1].call then
      each_decl(path, function(d) return d.kind == "error" end, function(d, here)
        items:decl(d, here and 1 or 2)
      end)
    elseif segments then
      member_completion(items, segments, scope, path)
    end
    return items:result()
  end

  -- A bare word: what is in scope, then public top-level names of every other file.
  local rank = 0
  local s = scope
  while s do
    for _, d in ipairs(s.order) do items:decl(d, rank) end
    rank = math.min(rank + 1, 2)
    s = s.parent
  end
  for _, name in ipairs(primitives) do items:add(name, K.type_param, 3, "primitive type") end
  for _, name in ipairs(keywords) do items:add(name, K.keyword, 3, "keyword") end
  if #query > 0 then
    for other, c in pairs(files) do
      if c and other ~= path and workspace_set[other] then
        for _, d in ipairs(c.order) do
          if d.pub then items:decl(d, 4) end
        end
      end
    end
  end
  return items:result()
end)

-- ---------------------------------------------------------------------------------------------
-- Startup: find the Zig lib directory, the module names and every .zig file
-- ---------------------------------------------------------------------------------------------

local function find_zig_lib()
  local env = os.getenv("ZIG_LIB_DIR")
  if env and env ~= "" then return env end
  local ok, out = pcall(ulsp.process.run, { cmd = { os.getenv("ZIG") or "zig", "env" } })
  if ok and out.code == 0 then return out.stdout:match('lib_dir"?%s*[=:]%s*"([^"]+)"') end
end

local function walk(dir, found)
  local ok, entries = pcall(ulsp.fs.list, dir)
  if not ok then return end
  for _, entry in ipairs(entries) do
    local name, path = entry.name, dir .. "/" .. entry.name
    if entry.kind == "directory" then
      if name:sub(1, 1) ~= "." and not name:match("^bazel%-") and not skip_dirs[name] then walk(path, found) end
    elseif entry.kind == "file" then
      if name:match("%.zig$") then
        found[#found + 1] = path
      elseif name == "BUILD.bazel" or name == "BUILD" then
        local read_ok, text = pcall(ulsp.fs.read, path)
        if read_ok then read_bazel(dir, text) end
      end
    end
  end
end

ulsp.add("initialized", function()
  zig_lib = find_zig_lib()
  if not ulsp.root then
    return
  end
  local started = os.clock()
  local found = {}
  walk(ulsp.root, found)
  workspace = found
  for _, path in ipairs(found) do workspace_set[path] = true end
  for i, path in ipairs(found) do
    get_file(path)
    if i % 8 == 0 then ulsp.sleep(0) end
  end
  local count = 0
  for _ in pairs(modules) do count = count + 1 end
  ulsp.log.info(string.format("zig: indexed %d files, %d modules, std at %s, in %.2fs cpu",
    #found, count, tostring(zig_lib), os.clock() - started))
end)

ulsp.log.info("zig: naive completion loaded")

-- ulsp scheduler. Receives `core`, returns the scheduler table.
-- Knows nothing about LSP: it needs only core.op_* and core.op_cancel, core.log.
local core = ...

local co_create, co_resume, co_yield, co_status, co_close, co_running, co_isyieldable =
  coroutine.create, coroutine.resume, coroutine.yield, coroutine.status,
  coroutine.close, coroutine.running, coroutine.isyieldable
local traceback = debug.traceback
local pack, unpack = table.pack, table.unpack

local S = {}

-- The unique cancellation value. Test with ==.
local canceled = setmetatable({}, { __tostring = function() return "ulsp.canceled" end })
S.canceled = canceled

local Future = {}
Future.__index = Future
local Group = {}
Group.__index = Group

local queue, qhead, qtail = {}, 1, 0
local current
local in_run = false
local ops = {} -- op id -> task waiting for it

local function push(t)
  qtail = qtail + 1
  queue[qtail] = t
end

local function pop()
  if qhead > qtail then return nil end
  local t = queue[qhead]
  queue[qhead] = nil
  qhead = qhead + 1
  if qhead > qtail then qhead, qtail = 1, 0 end
  return t
end

-- A task is its own future. Fields: co, state (ready|running|suspended|done),
-- want_cancel (flag), started, outcome, waiters (tasks waiting for it), undo,
-- woken (pack(ok, ...)), group, cb.

local function new_task(fn, ...)
  local args = pack(...)
  local t = setmetatable({
    state = "ready", want_cancel = false, started = false, waiters = {},
    co = co_create(function() return fn(unpack(args, 1, args.n)) end),
  }, Future)
  push(t)
  return t
end

function Future:__gc()
  local o = self.outcome
  if o and o.kind == "error" and not o.observed then
    core.log(1, "unobserved task error: " .. tostring(o.err) .. "\n" .. o.trace)
  end
end

-- wake a suspended task with (ok, ...). No-op if it is not suspended.
local function wake(t, ...)
  if t.state ~= "suspended" then return end
  t.undo = nil
  t.woken = pack(...)
  t.state = "ready"
  push(t)
end
S.wake = wake

local function finish(t, kind, ...)
  t.state = "done"
  local o = { kind = kind }
  if kind == "ok" then
    o.values = pack(...)
  elseif kind == "error" then
    o.err, o.trace = ...
  end
  t.outcome = o
  local g = t.group
  if g then
    g.done = g.done + 1
    if kind == "error" and not g.first_err then g.first_err = t end
  end
  local cb = t.cb
  if cb then
    t.cb = nil
    local ok, err = pcall(cb, t)
    if not ok then core.log(1, "task callback failed: " .. tostring(err)) end
  end
  local waiters = t.waiters
  t.waiters = {}
  for i = 1, #waiters do wake(waiters[i], true, t) end
  if g then
    local gw = g.waiters
    g.waiters = {}
    for i = 1, #gw do wake(gw[i], true) end
  end
end

local function step(t)
  if not t.started and t.want_cancel then
    finish(t, "canceled")
    return
  end
  t.started = true
  t.state = "running"
  current = t
  local res = pack(co_resume(t.co))
  current = nil
  if res[1] then
    if co_status(t.co) == "dead" then
      finish(t, "ok", unpack(res, 2, res.n))
    elseif t.state == "running" then
      -- A raw coroutine.yield: nothing could ever wake this task, so fail it loudly.
      co_close(t.co)
      finish(t, "error", "ulsp: coroutine.yield is not allowed in a ulsp task",
        "ulsp: coroutine.yield is not allowed in a ulsp task")
    end
  else
    local err = res[2]
    local trace = traceback(t.co, tostring(err))
    co_close(t.co)
    if err == canceled then
      finish(t, "canceled")
    else
      finish(t, "error", err, trace)
    end
  end
end

-- Run the queue until it is empty. Never entered recursively.
function S.run()
  if in_run then return end
  in_run = true
  while true do
    local t = pop()
    if not t then break end
    local ok, err = pcall(step, t)
    if not ok then
      -- A scheduler fault must not wedge `in_run` or the tasks behind this one.
      current = nil
      core.log(1, "scheduler error: " .. tostring(err))
    end
  end
  in_run = false
end

local function cannot() error("ulsp: cannot suspend here", 0) end

-- Steps 1 and 2 of every suspending call. Returns the running task.
local function check()
  local co, main = co_running()
  local t = current
  if main or not t or t.co ~= co or not co_isyieldable() then cannot() end
  if t.want_cancel then error(canceled, 0) end
  return t
end
S.check = check

-- Step 4: suspend; `undo` is called if the task is cancelled while waiting.
-- Returns (ok, ...) the wake values, without raising.
local function park_raw(t, undo)
  t.undo = undo
  t.state = "suspended"
  co_yield()
  local w = t.woken
  t.woken = nil
  return unpack(w, 1, w.n)
end

local function park(t, undo)
  local r = pack(park_raw(t, undo))
  if t.want_cancel then error(canceled, 0) end
  if not r[1] then error(r[2], 0) end
  return unpack(r, 2, r.n)
end

-- Generic suspending call for the prelude (e.g. waiting for a client response).
-- `undo` runs if the task is cancelled while waiting.
function S.suspend(undo)
  return park(check(), undo)
end

local function await_op(t, id)
  ops[id] = t
  return park(t, function()
    ops[id] = nil
    core.op_cancel(id)
  end)
end

-- Start op `name` (a core.op_* function), wait for it. Suspending call.
function S.op(name, ...)
  local t = check()
  return await_op(t, core[name](...))
end

function S.on_completion(id, ok, value)
  local t = ops[id]
  if not t then return end
  ops[id] = nil
  if ok then wake(t, true, value) else wake(t, false, value) end
end

function S.sleep(ms)
  if type(ms) ~= "number" or ms ~= ms or ms < 0 then
    error("ulsp.sleep: expected a number >= 0", 2)
  end
  local t = check()
  return await_op(t, core.op_sleep(ms))
end

function S.async(fn, ...)
  if type(fn) ~= "function" then error("ulsp.async: expected a function", 2) end
  return new_task(fn, ...)
end

-- Run `cb(future)` when the task finishes (from the scheduler, never suspends).
function S.on_done(f, cb)
  if f.state == "done" then cb(f) else f.cb = cb end
end

-- Outcome of a done future: kind, values | err, trace.
function S.outcome(f) return f.outcome end

function S.observe(f)
  if f.outcome then f.outcome.observed = true end
end

local function is_future(v) return getmetatable(v) == Future end

local function result(f)
  local o = f.outcome
  o.observed = true
  if o.kind == "ok" then return unpack(o.values, 1, o.values.n) end
  if o.kind == "canceled" then error(canceled, 0) end
  error(o.err, 0)
end

local function waiter_undo(list, t)
  return function()
    for i = 1, #list do
      if list[i] == t then table.remove(list, i) break end
    end
  end
end

function Future:await()
  if not is_future(self) then error("ulsp: expected a future", 2) end
  local t = check()
  if self.state ~= "done" then
    local w = self.waiters
    w[#w + 1] = t
    park(t, waiter_undo(w, t))
  end
  return result(self)
end

function Future:cancel()
  if self.state == "done" then return end
  self.want_cancel = true
  if self.state == "suspended" then
    local undo = self.undo
    self.undo = nil
    if undo then undo() end
    wake(self, true)
  end
end
Future.__close = Future.cancel


function S.select(...)
  local n = select("#", ...)
  if n == 0 then error("ulsp.select: expected at least one future", 2) end
  local fs = { ... }
  for i = 1, n do
    if not is_future(fs[i]) then error("ulsp.select: expected futures", 2) end
  end
  local t = check()
  for i = 1, n do
    if fs[i].state == "done" then return fs[i] end
  end
  for i = 1, n do
    local w = fs[i].waiters
    w[#w + 1] = t
  end
  local function undo()
    for i = 1, n do waiter_undo(fs[i].waiters, t)() end
  end
  local r = pack(park_raw(t, undo))
  undo()
  if t.want_cancel then error(canceled, 0) end
  if not r[1] then error(r[2], 0) end
  return r[2]
end

function S.group()
  return setmetatable({ members = {}, done = 0, waiters = {} }, Group)
end

function Group:async(fn, ...)
  if type(fn) ~= "function" then error("ulsp.group:async: expected a function", 2) end
  local t = new_task(fn, ...)
  t.group = self
  self.members[#self.members + 1] = t
  return t
end

function Group:cancel()
  local m = self.members
  for i = 1, #m do m[i]:cancel() end
end
Group.__close = Group.cancel

function Group:await()
  local t = check()
  local failed = false
  while true do
    local first_err = self.first_err
    if first_err and not failed then
      failed = true
      self:cancel()
    end
    if self.done == #self.members then
      for _, f in ipairs(self.members) do f.outcome.observed = true end
      if first_err then error(first_err.outcome.err, 0) end
      return
    end
    local w = self.waiters
    w[#w + 1] = t
    park_raw(t, waiter_undo(w, t))
    if t.want_cancel then
      waiter_undo(w, t)()
      self:cancel()
      error(canceled, 0)
    end
  end
end

return S

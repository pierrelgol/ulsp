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

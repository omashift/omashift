-- A fake Hyprland, so lib/engine.lua can be driven under plain `lua`.
--
-- WHY THIS EXISTS
--
-- For most of this project's life the rule was that `engine.lua` needs a live
-- compositor and therefore cannot be unit-tested. That rule shaped everything:
-- logic was pushed into core.lua to keep it testable, `./test/smoke` was built
-- to drive a real stage in a real Hyprland, and four separate edits to the
-- engine still broke silently with a fully green suite.
--
-- The rule turned out to be too strong. `engine.lua` touches exactly nine
-- `hl.*` functions, and only a couple of them need a compositor to mean
-- anything. Everything else (stage flow, scoring hand-off, the screens, the
-- co-driver, persistence, hand-back) is ordinary Lua sitting behind a very small
-- seam. Stub the seam and the file runs anywhere.
--
-- WHAT IS AND IS NOT COVERED
--
-- Covered: that the engine loads, that a stage runs start to finish, that the
-- screens it writes say what they should, and that configuration survives the
-- trip from the launcher to the thing that consumes it.
--
-- NOT covered, and still `./test/smoke`'s job: whether Hyprland actually
-- captures keys under a submap, whether a real keypress reaches the handler, and
-- whether the compositor is left in a sane state afterwards. A stub cannot have
-- an opinion about any of that.
--
-- TIME IS VIRTUAL, AND THAT IS THE POINT
--
-- `hl.timer` here schedules against a fake clock and `advance(ms)` fires what is
-- due, in due order. Draining every pending timer at once instead, which is the
-- obvious first attempt, immediately trips the idle-release watchdog and the
-- stage retires before it ever shows a prompt. Ordered virtual time is both more
-- faithful and more deterministic than real timers.

-- Replacing os.getenv is the entire point of the sandbox: each test box gets
-- its own environment, so the suites cannot leak into one another.
-- luacheck: globals os

local M = {}

-- Deterministic stages need a clean slate. History and the SM-2 schedule
-- accumulate on disk, and a second run with the same seed picks different
-- prompts because different items have come due. That is not seed flakiness, it
-- is state bleed, and it is the first thing to suspect if a case goes unstable.
local function rmrf(path) os.execute(("rm -rf %q"):format(path)) end
local function mkdirp(path) os.execute(("mkdir -p %q"):format(path)) end

-- os.time() alone is second-resolution, so two sandboxes built in the same
-- second would share a path and quietly stomp each other's history file. The
-- counter is what actually keeps them apart.
local box_seq = 0

-- An unpredictable, 0700 sandbox root.
--
-- These used to be built at /tmp/omashift-test-<name>-<time>-<seq>, which any
-- local process could guess and pre-place. Nothing secret is staged into a
-- sandbox, but a suite that a stranger runs on a shared machine should not be
-- the one predictable path left in the tree after the security review.
local function mktempd(name)
  local p = io.popen(("mktemp -d -t %s.XXXXXXXX 2>/dev/null"):format(name))
  if not p then return nil end
  local dir = p:read("*l")
  p:close()
  return (dir and #dir > 0) and dir or nil
end

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- A disposable OMASHIFT_BASE with the engine's dependencies staged into it,
-- laid out exactly the way bin/omashift stages the real one.
function M.sandbox(name)
  local here = (arg[0]:match("(.*/)") or "./")
  box_seq = box_seq + 1
  local root = mktempd(("omashift-test-%s-%d"):format(name, box_seq))
  assert(root, "could not create a sandbox directory")
  mkdirp(root .. "/lib")
  mkdirp(root .. "/state/omashift")

  for _, f in ipairs({ "core.lua", "trophies.lua", "screens.lua", "runtime.lua" }) do
    os.execute(("cp %q %q"):format(here .. "../lib/" .. f, root .. "/lib/" .. f))
  end
  -- Generated from the committed keybindings fixture, never from the machine
  -- running the suite, or the question bank would differ per developer.
  os.execute(("cp %q %q"):format(here .. "fixtures/inventory.lua", root .. "/lib/inventory.lua"))

  return {
    root  = root,
    state = root .. "/state/state.txt",
    json  = root .. "/state/state.json",
    text  = function(self) return read(self.state) end,
    model = function(self) return read(self.json) or "" end,
    screen = function(self) return (self:model():match('"screen":"([a-z_]+)"')) or "none" end,
    remove = function(self) rmrf(self.root) end,
  }
end

-- The engine reads its paths from the environment at load time, and Lua cannot
-- set environment variables. Overriding the reader is the in-process equivalent
-- and keeps the whole suite in one file rather than a shell wrapper.
function M.with_env(overrides)
  local real = os.getenv
  os.getenv = function(k)
    if overrides[k] ~= nil then return overrides[k] end
    return real(k)
  end
  return function() os.getenv = real end
end

-- Install the fake compositor. Returns a handle for driving it.
function M.install()
  local now, seq, pending = 0, 0, {}
  local held = {}
  -- The stub tracks the live submap the way the compositor does, because the
  -- watchdog asks the COMPOSITOR what is engaged rather than trusting the
  -- engine's own belief. A stub that answered from the engine's belief would
  -- make the watchdog untestable in exactly the state it exists for.
  local current_submap = ""
  local h = {
    binds = {}, submaps = {}, events = {}, exec = {},
    dispatched = {}, dispatches = 0, unbinds = 0,
  }

  _G.hl = {
    is_key_down = function(key) return held[key] == true end,

    timer = function(fn, opts)
      seq = seq + 1
      pending[#pending + 1] = {
        due = now + ((opts and tonumber(opts.timeout)) or 0), seq = seq, fn = fn,
      }
    end,

    -- Real binds return a keybind object. Returning a table with the same shape
    -- keeps the engine from having to care that it is talking to a stub.
    bind = function(keys)
      h.binds[#h.binds + 1] = keys
      return { set_enabled = function() end, remove = function() end }
    end,

    unbind        = function() h.unbinds = h.unbinds + 1 end,
    on            = function(event) h.events[#h.events + 1] = tostring(event) end,
    exec_cmd      = function(cmd) h.exec[#h.exec + 1] = tostring(cmd) end,

    -- Records WHAT was dispatched, not just that something was. Counting alone
    -- is too weak to be useful: the engine dispatches submap(omashift) to enter
    -- game mode, so a bare "did it dispatch" assertion passes even when the
    -- hand-back at the end never runs. That is precisely the regression this
    -- project already shipped once, and fault injection caught the weak
    -- assertion trying to let it through a second time.
    dispatch      = function(d)
      h.dispatches = h.dispatches + 1
      d = (type(d) == "table" and d) or { kind = "?" }
      h.dispatched[#h.dispatched + 1] = d
      if d.kind == "submap" then
        current_submap = (d.arg == "reset") and "" or tostring(d.arg)
      end
    end,

    get_current_submap = function() return current_submap end,

    -- The same virtual time the timers run on, so a reaction is exactly as long
    -- as the test says it is. Without this the engine read /proc/uptime while
    -- the timers ran on fake time, and a reaction time was however long the
    -- harness took to make two calls: near zero on an idle machine, longer on a
    -- busy one, and the screen goldens flaked on whichever it was.
    now_ms = function() return now end,

    define_submap = function(name, fn)
      h.submaps[#h.submaps + 1] = tostring(name)
      fn()
    end,

    -- Dispatchers are opaque to the ENGINE, which only builds them and hands
    -- them back to hl.dispatch. They are not opaque to the test: tagging each
    -- one with its name and argument is what makes "reset the submap" checkable.
    dsp = setmetatable({}, {
      __index = function(_, name)
        return function(a) return { kind = name, arg = a } end
      end,
    }),
  }

  function h.now() return now end

  -- Fire everything due within the window, earliest first, ties in the order
  -- they were scheduled. A timer scheduled DURING this call is honored if it
  -- also falls inside the window, which is what makes chained timers (the
  -- countdown, the co-driver) run to completion.
  function h.advance(ms)
    local target = now + ms
    while true do
      table.sort(pending, function(a, b)
        if a.due ~= b.due then return a.due < b.due end
        return a.seq < b.seq
      end)
      if #pending == 0 or pending[1].due > target then break end
      local t = table.remove(pending, 1)
      now = t.due
      t.fn()
    end
    now = target
  end

  -- Every submap the engine dispatched, in order. Entering game mode is
  -- submap("omashift"); handing the keys back is submap("reset").
  function h.submap_dispatches()
    local out = {}
    for _, d in ipairs(h.dispatched) do
      if d.kind == "submap" then out[#out + 1] = tostring(d.arg) end
    end
    return out
  end

  function h.dispatched_submap(name)
    for _, s in ipairs(h.submap_dispatches()) do
      if s == name then return true end
    end
    return false
  end

  function h.submap() return current_submap end

  -- Strand the keyboard the way a wedged stage does: submap engaged, nothing
  -- driving it. This is the state the watchdog exists for and the only way to
  -- test it is to create it.
  function h.strand(name) current_submap = name or "omashift" end

  function h.hold(...) for _, k in ipairs({ ... }) do held[k] = true end end
  function h.release_all() held = {} end
  function h.pending() return #pending end

  -- The engine guards its listener and submap on globals so a reload does not
  -- double-register. Tests load the engine repeatedly, so those have to go.
  function h.reset_globals()
    _G.omashift_submap_defined = nil
    _G.omashift_key_listener_bound = nil
    _G.omashift_generation = nil
    _G.omashift_start = nil
    _G.omashift_on_answer = nil
    _G.omashift_on_retire = nil
    _G.omashift_on_key = nil
    _G.omashift_on_watchdog = nil
    _G.omashift_watchdog_bound = nil
  end

  return h
end

return M

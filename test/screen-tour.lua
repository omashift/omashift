-- Every screen the engine can draw, and how to reach it.
--
-- Shared by test/capture-screens.lua (which writes the goldens) and
-- test/test-screens.lua (which replays them). One definition, so a screen cannot
-- be captured one way and asserted another, and adding a screen means adding it
-- in exactly one place.
--
-- Each step gets its OWN sandbox. That costs a few milliseconds and buys
-- determinism: history and the SM-2 schedule accumulate on disk and change what
-- comes due, so screens driven in sequence through a shared sandbox drift.

local M = {}

local HERE = (arg[0]:match("(.*/)") or "./")
local H = dofile(HERE .. "hl-stub.lua")
local ENGINE = HERE .. "../lib/engine.lua"
local INVENTORY = dofile(HERE .. "fixtures/inventory.lua")

M.FAR = 60 * 60 * 1000

local function combo_for(d)
  for _, e in ipairs(INVENTORY) do if e.description == d then return e.combo end end
end

local function boot()
  local box = H.sandbox("tour")
  local hl = H.install()
  hl.reset_globals()
  local env = {
    OMASHIFT_BASE       = box.root,
    OMASHIFT_STATE      = box.state,
    OMASHIFT_STATE_JSON = box.json,
    XDG_STATE_HOME      = box.root .. "/state",
    XDG_CONFIG_HOME     = box.root .. "/config",
  }
  local restore = H.with_env(env)
  dofile(ENGINE)
  restore()

  -- Anything that reaches into the engine has to run under the overridden
  -- environment, or the engine writes its screens to the real /tmp paths and the
  -- tour silently describes a different run than the one being inspected.
  local function under(fn)
    local r = H.with_env(env)
    local ok, err = pcall(fn)
    r()
    if not ok then error(err, 0) end
  end

  return { hl = hl, box = box, under = under, combo_for = combo_for }
end

local function stage_opts(extra)
  local o = { length = 3, seed = 42, idle_release_ms = M.FAR, course = "daily-driver" }
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

local function to_prompt(c, extra)
  c.under(function()
    _G.omashift_start(stage_opts(extra))
    c.hl.advance(6000)
  end)
end

local function prompt_description(c)
  return c.box:model():match('"prompt":%s*{.-"description":"([^"]*)"')
end

-- Ordered so a reader can follow a session top to bottom.
M.steps = {
  -- Drawn at load, before anything else. It had no model at all before the
  -- render/publish merge, which made it the easiest screen to lose.
  { name = "loaded", drive = function() end },

  { name = "ready", drive = function(c)
      c.under(function() _G.omashift_preview(10, 2000, "daily-driver", "medium") end)
    end },

  { name = "countdown", drive = function(c)
      c.under(function() _G.omashift_start(stage_opts()) end)
    end },

  -- The LFG beat. Advance until the model SAYS it, rather than guessing the tick
  -- count: a fixed advance captured n=1 the first time, and since "4" and "1" are
  -- both one character the wrong fixture was exactly the same size as the right
  -- one and the mistake looked like a success.
  { name = "countdown-lfg", drive = function(c)
      c.under(function()
        _G.omashift_start(stage_opts())
        for _ = 1, 20 do
          if c.box:model():match('"lfg":true') then break end
          c.hl.advance(1000)
        end
      end)
      assert(c.box:model():match('"lfg":true'), "never reached the LFG frame")
    end },

  { name = "prompt", drive = function(c) to_prompt(c) end },

  { name = "prompt-hinted", drive = function(c)
      to_prompt(c)
      c.under(function() c.hl.advance(10000) end)
      assert(c.box:model():match('"hint"'), "the co-driver never spoke")
    end },

  -- The flash after an answer, before the next note. One millisecond, because a
  -- longer advance moves past it.
  { name = "result", drive = function(c)
      to_prompt(c)
      c.under(function()
        _G.omashift_on_answer(c.combo_for(prompt_description(c)))
        c.hl.advance(1)
      end)
    end },

  -- The same screen after a WRONG answer, which is a different shape: it names
  -- what was pressed as well as what was wanted.
  { name = "result-off", drive = function(c)
      to_prompt(c)
      c.under(function()
        local want = prompt_description(c)
        local wrong
        -- A REAL binding that is not the answer. The submap only routes combos
        -- that exist, so an invented one would not reach the engine at all.
        for _, e in ipairs(INVENTORY) do
          if e.description ~= want then wrong = e.combo break end
        end
        _G.omashift_on_answer(wrong)
        c.hl.advance(1)
      end)
    end },

  -- The one end-of-stage page: summary, trophies, ladder, splits, every note.
  { name = "results", drive = function(c)
      to_prompt(c)
      c.under(function()
        for _ = 1, 10 do
          local d = prompt_description(c)
          if not d then break end
          _G.omashift_on_answer(c.combo_for(d))
          c.hl.advance(1500)
        end
      end)
    end },

  -- Both release reasons. They share a screen name and differ only in `reason`,
  -- which is exactly the case a fixture keyed on screen alone would half-cover.
  { name = "released-retired", drive = function(c)
      to_prompt(c, { length = 5 })
      c.under(function() _G.omashift_on_retire() end)
    end },

  { name = "released-idle", drive = function(c)
      c.under(function()
        _G.omashift_start(stage_opts({ length = 5, idle_release_ms = 5000 }))
        c.hl.advance(6000)
        c.hl.advance(30000)          -- walk away
      end)
    end },

  { name = "empty_course", drive = function(c)
      c.under(function() _G.omashift_start(stage_opts({ course = "blind-spots" })) end)
    end },
}

-- Drive one step and hand back its sandbox. The caller owns cleanup.
function M.run(step)
  local c = boot()
  step.drive(c)
  return c.box
end

return M

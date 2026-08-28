-- Tests for lib/screens.lua, the single source of every screen's text.
-- Run directly:  lua test/test-screens.lua
--
-- The load-bearing half is the byte-for-byte replay: every screen the engine can
-- draw is driven for real and compared against a golden captured BEFORE the
-- render/publish merge. That is the whole proof that collapsing nineteen call
-- sites into one changed nothing a player can see.
--
-- If one of those fails, suspect the formatter, not the golden. Regenerating the
-- goldens to get back to green discards the only evidence the refactor was safe.

local HERE = (arg[0]:match("(.*/)") or "./")
package.path = HERE .. "../lib/?.lua;" .. package.path
local screens = require("screens")
local tour = dofile(HERE .. "screen-tour.lua")

local run, failed = 0, 0

local function ok(label)
  run = run + 1
  print(("  \27[32mok\27[0m   %s"):format(label))
end

local function fail(label, expected, actual)
  run, failed = run + 1, failed + 1
  print(("  \27[31mFAIL\27[0m %s"):format(label))
  print(("       expected: %s"):format(tostring(expected)))
  print(("       actual:   %s"):format(tostring(actual)))
end

local function eq(label, expected, actual)
  if expected == actual then ok(label) else fail(label, expected, actual) end
end

local function truthy(label, v)
  if v then ok(label) else fail(label, "truthy", tostring(v)) end
end

local function contains(label, needle, hay)
  if type(hay) == "string" and hay:find(needle, 1, true) then ok(label)
  else fail(label, "contains " .. needle, hay) end
end

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

-- Report the first differing line rather than dumping two whole screens. A
-- results page is forty lines and an unhelpful diff is why golden tests get
-- ignored.
local function first_difference(a, b)
  local ai, bi = {}, {}
  for l in (a or ""):gmatch("[^\n]*") do ai[#ai + 1] = l end
  for l in (b or ""):gmatch("[^\n]*") do bi[#bi + 1] = l end
  for i = 1, math.max(#ai, #bi) do
    if ai[i] ~= bi[i] then
      return ("line %d\n         golden: %q\n         actual: %q"):format(
        i, tostring(ai[i]), tostring(bi[i]))
    end
  end
  return "identical"
end

print("screens (byte-for-byte replay of the pre-merge goldens):")

local seen_screens = {}

for _, step in ipairs(tour.steps) do
  local golden = read(("%sfixtures/screens/%s.txt"):format(HERE, step.name))
  if not golden then
    fail("golden exists for " .. step.name, "a captured fixture",
         "missing -- run lua test/capture-screens.lua")
  else
    local box = tour.run(step)
    local actual = box:text()
    local model = box:model()
    if actual == golden then
      ok(("%s renders exactly as captured"):format(step.name))
    else
      fail(("%s renders exactly as captured"):format(step.name),
           "byte-identical", first_difference(golden, actual))
    end
    -- THE MODEL IS HALF THE CONTRACT, and until now it was the half nothing
    -- checked. capture-screens.lua writes a (model, text) pair and says the
    -- pair IS the contract, but only the text was ever asserted, so the
    -- recorded models were write-only files that rotted quietly: every one of
    -- them still carried a scrim that core.lua had changed commits earlier,
    -- and no test noticed because a scrim does not reach the text.
    local model_golden = read(("%sfixtures/screens/%s.json"):format(HERE, step.name))
    if not model_golden then
      fail(("%s publishes exactly as captured"):format(step.name),
           "a captured model", "missing -- run lua test/capture-screens.lua")
    elseif (model or "") == model_golden then
      ok(("%s publishes exactly as captured"):format(step.name))
    else
      fail(("%s publishes exactly as captured"):format(step.name),
           "byte-identical", first_difference(model_golden, model or ""))
    end

    local name = model and model:match('"screen":"([a-z_]+)"')
    if name then seen_screens[name] = true end
    box:remove()
  end
end

print()
print("screens (coverage):")

-- Every screen name ANY producer publishes must have a formatter. Read from the
-- sources rather than a hand-kept list, so a new screen cannot be added without
-- either a renderer or a failure here.
--
-- Three producers, not one. The engine publishes the screens a stage draws; the
-- cabinet and the logbook publish their own, because a trophy case and a career
-- record are not things a stage produces. Scanning only the engine made the
-- cabinet formatter look orphaned.
local engine_src = read(HERE .. "../lib/engine.lua") or ""
local cabinet_src = read(HERE .. "../lib/cabinet.lua") or ""
local stats_src = read(HERE .. "../lib/stats.lua") or ""

-- Screens a STAGE draws. These are the ones the tour has to reach.
local engine_screens = {}
for name in engine_src:gmatch('screen%s*=%s*"([a-z_]+)"') do engine_screens[name] = true end

local published = {}
for name in pairs(engine_screens) do published[name] = true end
for name in cabinet_src:gmatch('screen%s*=%s*"([a-z_]+)"') do published[name] = true end
for name in stats_src:gmatch('screen%s*=%s*"([a-z_]+)"') do published[name] = true end

truthy("the engine publishes at least one screen", next(engine_screens) ~= nil)
truthy("and the cabinet publishes its own", published["cabinet"] == true)
truthy("and the logbook publishes its own", published["stats"] == true)

local known = {}
for _, n in ipairs(screens.names()) do known[n] = true end

for name in pairs(published) do
  if known[name] then ok(("the engine's %q screen has a formatter"):format(name))
  else fail(("the engine's %q screen has a formatter"):format(name), "a branch in screens.lua", "none") end
end

-- And the other direction: a formatter nothing publishes is dead code that will
-- rot without anyone noticing.
for name in pairs(known) do
  if published[name] then ok(("the %q formatter is actually used"):format(name))
  else fail(("the %q formatter is actually used"):format(name), "published by the engine", "orphaned") end
end

-- The tour has to reach every screen a STAGE draws, or the replay above is
-- quietly partial. The cabinet is deliberately not in it: nothing a stage does
-- produces one, and its own goldens are asserted further down.
for name in pairs(engine_screens) do
  if seen_screens[name] then ok(("the tour reaches %q"):format(name))
  else fail(("the tour reaches %q"):format(name), "a step that renders it", "never reached") end
end

print()
print("screens (called directly):")

-- A blank screen is indistinguishable from a hung game, so an unknown screen
-- name has to say something.
local unknown = screens.text({ screen = "nonsense" })
contains("an unknown screen names itself", "unknown screen: nonsense", unknown)
contains("and says where the bug is", "bug in the engine", unknown)

local nothing = screens.text(nil)
truthy("a nil model still renders something", #nothing > 0)
contains("and admits it has nothing", "no screen to draw", nothing)

-- The engine publishes from a live stage that can be torn down between the model
-- being built and the screen being drawn, so a missing block must not throw.
local bare = screens.render({ screen = "prompt" })
truthy("a prompt with no stage block does not error", #bare > 0)
local bare_results = screens.render({ screen = "results" })
truthy("results with no summary does not error", #bare_results > 0)

-- The gearbox is drawn from the model's own max, not a constant.
local geared = table.concat(screens.render({
  screen = "prompt", stage = { index = 1, total = 3, gear = 2, max_gear = 4, points = 0 },
  prompt = { description = "x" },
}), "\n")
contains("the gear bar fills to the current gear", "[ 1 2 - - ]", geared)

-- The ladder is suppressed when nothing was graded, and `graded` is not a field:
-- it is the sum of the tier counts, so the fact is already in the data.
local ungraded = table.concat(screens.render({
  screen = "results", summary = { correct = 0, prompts = 1, offs = 1 },
  ladder = { { name = "zero-latency", count = 0, share = 0 } },
  splits = {}, notes = {}, trophies = {},
}), "\n")
eq("no ladder when nothing was graded", nil, ungraded:match("LADDER"))

local graded = table.concat(screens.render({
  screen = "results", summary = { correct = 1, prompts = 1 },
  ladder = { { name = "zero-latency", count = 1, share = 1 } },
  splits = {}, notes = {}, trophies = {},
}), "\n")
contains("a ladder once something was graded", "LADDER", graded)

-- THE GHOST. No captured stage has one, because a ghost needs a personal best
-- from a previous run and every fixture is played in a clean sandbox. Fault
-- injection found the hole: renaming ghost_gap_s on the engine side left the
-- whole suite green. These call the formatter directly so the path is covered,
-- and test-wiring.sh pins the key names on the engine side.
local beat = table.concat(screens.render({
  screen = "result", stage = { index = 1, total = 3, points = 100 },
  result = { outcome = "correct", tier = "clean", speed_kmh = 90, points = 100,
             expected = "SUPER + F", description = "Full screen",
             ghost_gap_s = -0.34, ghost_kmh = 70, best = true },
}), "\n")
contains("a new personal best is announced", "NEW BEST", beat)
contains("and the gap is signed", "-0.34s", beat)

local lost = table.concat(screens.render({
  screen = "result", stage = { index = 1, total = 3, points = 100 },
  result = { outcome = "correct", tier = "steady", speed_kmh = 50, points = 50,
             expected = "SUPER + F", description = "Full screen",
             ghost_gap_s = 0.52, ghost_kmh = 70, best = false },
}), "\n")
contains("losing to the ghost shows the ghost's speed", "ghost 70 km/h", lost)
-- Signed on purpose: "+0.52" against "-0.52" is the entire reading, and an
-- unsigned number would make you work out which side of it you are on.
contains("and a positive gap keeps its sign", "+0.52s", lost)

local ghost_summary = table.concat(screens.render({
  screen = "results",
  summary = { correct = 3, prompts = 3, ghost_gap_s = -1.2, ghost_notes = 2, ghost_beat = 2 },
  ladder = {}, splits = {}, notes = {}, trophies = {},
}), "\n")
contains("the summary reports the ghost gap", "vs ghost  -1.20s over 2 notes", ghost_summary)
contains("and how many were beaten", "(2 beaten)", ghost_summary)

-- One note reads "note", not "notes".
local one_note = table.concat(screens.render({
  screen = "results",
  summary = { correct = 1, prompts = 1, ghost_gap_s = -0.1, ghost_notes = 1, ghost_beat = 1 },
  ladder = {}, splits = {}, notes = {}, trophies = {},
}), "\n")
contains("a single ghost note is not pluralised", "over 1 note ", one_note)

-- THE WAY OUT. During a stage every keybinding is a game answer, so
-- `omashift --stop` needs a terminal the player cannot open. The on-screen hint
-- is the only escape hatch, and it was missing from the QML overlay entirely,
-- which is the display the config actually selects.
local playing = table.concat(screens.render({
  screen = "prompt", stage = { index = 1, total = 3, points = 0 },
  prompt = { description = "Close window" }, retire_key = "SUPER + SHIFT + ESCAPE",
}), "\n")
-- The terminal parenthesises it; the overlay lays it out its own way. Only the
-- CHORD is shared, which is the part that could drift into a lie.
contains("the in-play screen shows the way out", "(SUPER + SHIFT + ESCAPE to retire)", playing)

-- No silent default. A default that happens to be the right chord would hide an
-- engine that stopped publishing it, which is exactly what launch_key did.
local mute = table.concat(screens.render({
  screen = "prompt", stage = { index = 1, total = 3, points = 0 },
  prompt = { description = "Close window" },
}), "\n")
contains("a missing retire chord is visible, not defaulted", "no retire key in the model", mute)

-- And it must NOT appear once the stage is over: the submap is reset by then,
-- so the chord does nothing and the hint would be a lie.
local done = table.concat(screens.render({
  screen = "results", summary = { correct = 1, prompts = 1 },
  ladder = {}, splits = {}, notes = {}, trophies = {}, retire_key = "SUPER + SHIFT + ESCAPE",
}), "\n")
eq("the results page does not advertise a chord that no longer works", nil, done:match("to retire"))

-- The launch chord comes from the model. Hardcoding it in the formatter would
-- put the same bug in a new place, since a renderer cannot know what launched
-- the game.
local ready = table.concat(screens.render({
  screen = "ready", notes = 10, codriver_s = 2, launch_key = "SUPER + ALT + Z",
}), "\n")
contains("the ready screen shows the launch chord it was given", "SUPER + ALT + Z", ready)

-- And says so loudly when it was given none. A default that happened to be the
-- right answer is what let a dropped launch_key render a perfect screen.
local chordless = table.concat(screens.render({ screen = "ready", notes = 10, codriver_s = 2 }), "\n")
contains("a missing launch chord is visible, not defaulted", "no launch key in the model", chordless)

print()
print("cabinet (byte-for-byte against the pre-refactor terminal output):")

-- The trophy case used to be computed AND formatted in one pass inside a bash
-- heredoc. These goldens were captured from that version BEFORE lib/cabinet.lua
-- and R.cabinet existed, so they are the proof that moving the reading into a
-- module the overlay can share changed nothing a reader sees.
do
  local core = require("core")
  local C = require("cabinet")

  local f = io.open(HERE .. "fixtures/cabinet/omashift/trophies.json", "r")
  if not f then
    fail("the cabinet fixture exists", "a saved cabinet", "missing")
  else
    local saved = core.parse_cabinet(f:read("*a"))
    f:close()

    local courses = {}
    for _, n in ipairs(core.course_names()) do courses[#courses + 1] = n end

    for _, case in ipairs({ { why = false, file = "expected.txt" },
                            { why = true,  file = "expected-why.txt" } }) do
      local model = C.model(saved, courses)
      model.why = case.why
      local actual = table.concat(screens.render(model), "\n") .. "\n"
      local golden = read(HERE .. "fixtures/cabinet/" .. case.file)
      local label = case.why and "the --why listing is unchanged" or "the listing is unchanged"
      if actual == golden then ok(label)
      else fail(label, "byte-identical", first_difference(golden, actual)) end
    end
  end
end

print()
if failed == 0 then
  print(("\27[32mscreens: %d passed\27[0m"):format(run))
  os.exit(0)
end
print(("\27[31mscreens: %d of %d FAILED\27[0m"):format(failed, run))
os.exit(1)

-- Tests for lib/core.lua: all game logic, no compositor required.
-- Run directly:  lua test/test-core.lua

package.path = (arg[0]:match("(.*/)") or "./") .. "../lib/?.lua;" .. package.path
local core = require("core")

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

print("core:")

-- --- reaction tiers --------------------------------------------------------
-- Boundaries are CALIBRATED against 76 real answers, not guessed: this game
-- measures recall, not recognition, and the original 200/300ms tiers meant the
-- gearbox (which upshifts only on sub-300ms answers) had never once fired.
eq("sub-600ms is zero-latency",        "zero-latency", core.tier_for(150).name)
eq("600ms is still zero-latency",      "zero-latency", core.tier_for(600).name)
eq("601ms drops to on-rails",          "on-rails",     core.tier_for(601).name)
-- The anchor: the fastest answer ever recorded has to be reachable praise.
eq("the 780ms personal best is on-rails", "on-rails",  core.tier_for(780).name)
eq("900ms is the top of on-rails",     "on-rails",     core.tier_for(900).name)
eq("901ms is clean",                   "clean",        core.tier_for(901).name)
eq("1250ms is the top of clean",       "clean",        core.tier_for(1250).name)
eq("1751ms is slow",                   "slow",         core.tier_for(1751).name)
eq("very slow falls through",          "slow",         core.tier_for(99999).name)

-- --- difficulty scales the whole ladder ------------------------------------
eq("hard tightens the ladder",         "clean",        core.tier_for(780, 0.7).name)
eq("easy loosens it",                  "zero-latency", core.tier_for(780, 1.4).name)
eq("scale 1 is the plain ladder",      "on-rails",     core.tier_for(780, 1).name)
-- A bad scale must not silently rescore everything as zero-latency.
eq("a nil scale means 1",              "on-rails",     core.tier_for(780, nil).name)
eq("a zero scale falls back to 1",     "on-rails",     core.tier_for(780, 0).name)
eq("a negative scale falls back to 1", "on-rails",     core.tier_for(780, -3).name)
-- math.huge stays huge under any scale, so there is always a fallthrough.
eq("the last tier catches under hard", "slow",         core.tier_for(1e9, 0.7).name)
eq("the last tier catches under easy", "slow",         core.tier_for(1e9, 1.4).name)

-- --- difficulty presets ----------------------------------------------------
-- One table, in core, is the ONLY place these numbers live: the launcher passes
-- the mode's name and resolves nothing, so bash cannot drift from Lua.
eq("medium is the calibrated default", "Medium", core.difficulty(nil).label)
eq("a typo falls back to the default", "Medium", core.difficulty("nonsense").label)
truthy("hard tightens the tiers",  core.difficulty("hard").tier_scale < 1)
truthy("easy loosens the tiers",   core.difficulty("easy").tier_scale > 1)
-- Harder must mean LESS help, not just tighter scoring.
truthy("hard makes the co-driver wait longer",
  core.difficulty("hard").hint_mods > core.difficulty("medium").hint_mods)
truthy("easy makes it speak sooner",
  core.difficulty("easy").hint_full < core.difficulty("medium").hint_full)
for _, name in ipairs({ "easy", "medium", "hard" }) do
  local d = core.difficulty(name)
  truthy(("%s reveals modifiers before the full combo"):format(name), d.hint_mods < d.hint_full)
end
-- A clock hiccup must not crash a stage mid-run.
eq("nil reaction degrades to slow",    "slow",         core.tier_for(nil).name)
eq("negative reaction degrades to slow","slow",        core.tier_for(-5).name)

-- --- gears -----------------------------------------------------------------
eq("gears clamp at 4",  4, core.upshift(4))
eq("gears clamp at 1",  1, core.downshift(1))
eq("upshift steps by one", 3, core.upshift(2))
eq("downshift steps by one", 2, core.downshift(3))

-- --- determinism -----------------------------------------------------------
local inv = {}
for i = 1, 20 do
  inv[i] = { combo = "C" .. i, description = "d" .. i, modmask = (i % 4) * 8 }
end
local a = core.new_stage(inv, { length = 8, seed = 7 })
local b = core.new_stage(inv, { length = 8, seed = 7 })
local same = true
for i = 1, #a.prompts do
  if a.prompts[i].combo ~= b.prompts[i].combo then same = false end
end
truthy("same seed reproduces the same stage", same)

local c = core.new_stage(inv, { length = 8, seed = 8 })
local differs = false
for i = 1, #a.prompts do
  if a.prompts[i].combo ~= c.prompts[i].combo then differs = true end
end
truthy("a different seed produces a different stage", differs)

-- --- modmask spreading -----------------------------------------------------
-- Consecutive prompts sharing a modmask leak the answer: the player pre-loads
-- the modifiers and only reaction-times the key.
local clumped = {
  { combo = "a", modmask = 64 }, { combo = "b", modmask = 64 },
  { combo = "c", modmask = 64 }, { combo = "d", modmask = 8 },
  { combo = "e", modmask = 8 },  { combo = "f", modmask = 1 },
}
local spread = core.spread_modmask(clumped)
eq("spreading preserves every entry", #clumped, #spread)
local adjacent = 0
for i = 2, #spread do
  if spread[i].modmask == spread[i - 1].modmask then adjacent = adjacent + 1 end
end
truthy("spreading reduces adjacent same-modmask pairs", adjacent < 3)

-- --- answering -------------------------------------------------------------
local stage = core.new_stage(inv, { length = 3, seed = 1 })
local p = core.next_prompt(stage, 1000)
truthy("a stage yields a first prompt", p ~= nil)

local r = core.answer(stage, p.combo, 1150)
eq("correct answer is scored correct", "correct", r.outcome)
eq("reaction time is the delta from prompt", 150, r.reaction_ms)
eq("fast correct answer earns the top tier", "zero-latency", r.tier)
truthy("points were awarded", r.points > 0)

-- The difficulty scale has to REACH SCORING, not just sit on the stage table.
-- Threading it as far as new_stage and forgetting to consume it in answer()
-- would look correct everywhere except the one place it matters.
local function scored_at(scale, reaction)
  local st = core.new_stage(inv, { length = 3, seed = 1, tier_scale = scale })
  local pr = core.next_prompt(st, 0)
  return core.answer(st, pr.combo, reaction).tier
end
eq("a stage without a scale scores plainly", "on-rails", scored_at(nil, 780))
eq("a hard stage scores the same answer lower", "clean", scored_at(0.7, 780))
eq("an easy stage scores it higher", "zero-latency", scored_at(1.4, 780))

local p2 = core.next_prompt(stage, 2000)
local wrong = core.answer(stage, "SUPER + NOPE", 2200, "Close window")
eq("wrong answer is an off", "off", wrong.outcome)
eq("an off downshifts", 1, wrong.gear)
-- The teaching signal is the whole point of naming the wrong press.
eq("an off names what was actually pressed", "Close window", wrong.pressed_was)
eq("an off reports what was expected", p2.combo, wrong.expected)
eq("an off scores nothing", 0, wrong.points)
eq("an off resets the streak", 0, stage.streak)

-- --- reaction time as speed --------------------------------------------------
-- Each pace note is a corner you are timed through, so a fixed distance over
-- your time IS a speed. That makes this d/t rather than an arbitrary rescaling,
-- and 1/t is also what puts the resolution where real play actually sits.
eq("the anchor point is top speed", core.SPEED.top_kmh, core.speed_kmh(core.SPEED.at_ms))
truthy("faster than the anchor is capped, not extrapolated",
  core.speed_kmh(100) == core.SPEED.top_kmh)
truthy("slower means slower", core.speed_kmh(1250) > core.speed_kmh(1750))
-- Within 1 km/h, because each value is rounded independently: 2400ms is 62.5,
-- which rounds to 63, and 63*2 is not 125. The relationship is exact; the
-- displayed integers are not, and asserting on them would be asserting on the
-- rounding rather than the property.
truthy("halving the time doubles the speed",
  math.abs(core.speed_kmh(2400) * 2 - core.speed_kmh(1200)) <= 1)
truthy("quartering it quadruples the speed",
  math.abs(core.speed_kmh(4800) * 4 - core.speed_kmh(1200)) <= 2)

-- Zero means stopped, and there are three ways to stop.
eq("no answer is stopped", 0, core.speed_kmh(nil))
eq("a nonsense time is stopped", 0, core.speed_kmh(-5))
eq("an away-length pause is stopped", 0, core.speed_kmh(core.AWAY_MS))
eq("beyond away is still stopped", 0, core.speed_kmh(core.AWAY_MS * 2))
truthy("just under away still registers", core.speed_kmh(core.AWAY_MS - 1) > 0)

-- Absolute, never scaled by difficulty. Easy mode reporting faster numbers for
-- the same time would be flattering the player with a lie.
eq("speed does not depend on difficulty", core.speed_kmh(1000), core.speed_kmh(1000))

-- Average speed over equal distances is total distance over total time, NOT
-- the mean of the individual speeds, which would let one very fast note flatter
-- a slow stage.
local sinv = {}
for i = 1, 6 do sinv[i] = { combo = "S" .. i, modmask = 64, description = "N" .. i } end
local sstage = core.new_stage(sinv, { length = 2, seed = 1 })
local sp1 = core.next_prompt(sstage, 0); core.answer(sstage, sp1.combo, 600)
local sp2 = core.next_prompt(sstage, 0); core.answer(sstage, sp2.combo, 1800)
local ssum = core.summary(sstage)
eq("average speed comes from the average time", core.speed_kmh(1200), ssum.average_kmh)
truthy("...which is not the mean of the speeds",
  ssum.average_kmh ~= math.floor((core.speed_kmh(600) + core.speed_kmh(1800)) / 2 + 0.5))
eq("top speed is the fastest note", core.speed_kmh(600), ssum.top_kmh)
eq("the fastest time is carried too", 600, ssum.fastest_ms)
local empty_sum = core.summary(core.new_stage(sinv, { length = 1, seed = 1 }))
eq("an unanswered stage has no average speed", nil, empty_sum.average_kmh)
eq("...and no top speed", nil, empty_sum.top_kmh)

-- --- the ladder breakdown --------------------------------------------------
-- Splits say which KIND of thing was slow; this says how the whole stage sat on
-- the scale. It is what makes a difficulty change visible rather than claimed.
local ladder_stage = { results = {
  { outcome = "correct", tier = "on-rails" },
  { outcome = "correct", tier = "slow" },
  { outcome = "correct", tier = "slow" },
  { outcome = "off",     tier = nil },
  { outcome = "correct", tier = "steady" },
} }
local rows, graded = core.tier_counts(ladder_stage)
eq("only graded answers are counted", 4, graded)
eq("every tier is returned, empty ones included", #core.TIERS, #rows)
eq("the ladder is fastest first", "zero-latency", rows[1].name)
eq("an unreached tier reports zero rather than vanishing", 0, rows[1].count)
local by = {}
for _, r in ipairs(rows) do by[r.name] = r end
eq("on-rails counted",  1, by["on-rails"].count)
eq("slow counted",      2, by["slow"].count)
eq("shares are of graded answers", 50, math.floor(by["slow"].share * 100 + 0.5))
-- An off has no tier, so it must not land anywhere on the ladder.
eq("an off is not a tier", 0, by["clean"].count)
local none, zero = core.tier_counts({ results = {} })
eq("an empty stage grades nothing", 0, zero)
eq("...but still names every tier", #core.TIERS, #none)
eq("...with no divide-by-zero", 0, none[1].share)

-- --- the gearbox -----------------------------------------------------------
-- Pinned to the top two tiers, upshift fired on 1 answer in 76 of real play, so
-- the points multiplier sat at x1 for the life of the tool. A mechanic that
-- cannot activate is not difficulty, it is dead weight.
eq("tier rank is fastest-first", 1, core.tier_rank("zero-latency"))
truthy("slow ranks below the upshift tier",
  core.tier_rank("slow") > core.tier_rank(core.UPSHIFT_TIER))
eq("an unknown tier ranks last", #core.TIERS, core.tier_rank("nonsense"))

local ginv2 = {
  { combo = "SUPER + A", modmask = 64, description = "A" },
  { combo = "SUPER + B", modmask = 64, description = "B" },
  { combo = "SUPER + C", modmask = 64, description = "C" },
  { combo = "SUPER + D", modmask = 64, description = "D" },
}
-- Drive a stage with chosen reaction times and report the gear it ends in.
local function drive(times)
  local st = core.new_stage(ginv2, { length = #times, seed = 1 })
  for _, ms in ipairs(times) do
    local pr = core.next_prompt(st, 0)
    if pr then core.answer(st, pr.combo, ms) end
  end
  return st
end
-- Two qualifying answers is one upshift; the gearbox is deliberately not
-- twitchy enough to move on every note.
eq("one fast answer does not upshift", 1, drive({ 500 }).gear)
eq("two in a chain upshift",           2, drive({ 500, 500 }).gear)
eq("four in a chain reach third",      3, drive({ 500, 500, 500, 500 }).gear)
-- Momentum is what a slow answer costs. It is not a crash, so it must not
-- downshift -- but it must break the chain, or "chain" means nothing.
local stalled = drive({ 500, 9000, 500 })
eq("a slow answer does not downshift", 1, stalled.gear)
eq("a slow answer breaks the chain",   1, stalled.streak)
eq("a slow answer alone never upshifts", 1, drive({ 9000, 9000, 9000, 9000 }).gear)
-- The rule is one TIER NAME; difficulty moves the boundary under it, so the
-- same chain that upshifts on easy need not on hard.
local function geared(scale, times)
  local st = core.new_stage(ginv2, { length = #times, seed = 1, tier_scale = scale })
  for _, ms in ipairs(times) do
    local pr = core.next_prompt(st, 0)
    if pr then core.answer(st, pr.combo, ms) end
  end
  return st.gear
end
eq("easy upshifts on a pace hard refuses", 2, geared(1.4, { 2000, 2000 }))
eq("hard refuses the same pace",           1, geared(0.7, { 2000, 2000 }))

-- --- courses ---------------------------------------------------------------
-- The unfiltered bank is 52% three-modifier combos. Serving that at random to a
-- new player is unwinnable, which is exactly what the first playtest showed.
local bank = {
  { combo = "SUPER + RETURN",            modmask = 64, description = "Terminal" },
  { combo = "SUPER + W",                 modmask = 64, description = "Close window" },
  { combo = "SUPER + 1",                 modmask = 64, description = "Switch to workspace 1" },
  { combo = "SUPER + ALT + SHIFT + 0",   modmask = 73, description = "Move window silently to workspace 10" },
  { combo = "SUPER + CTRL + SHIFT + SPACE", modmask = 69, description = "Theme menu" },
  { combo = "SUPER + SHIFT + 3",         modmask = 65, description = "Move window to workspace 3" },
}
local dd = core.filter_course(bank, "daily-driver")
truthy("daily-driver keeps the everyday bindings", #dd > 0)
local has_expert = false
for _, e in ipairs(dd) do
  if e.description:match("silently") or e.description == "Theme menu" then has_expert = true end
end
eq("daily-driver excludes expert bindings", false, has_expert)
truthy("daily-driver is smaller than the whole bank", #dd < #bank)

local commute = core.filter_course(bank, "the-commute")
truthy("the-commute picks up move-to-workspace", #commute > 0)

-- APPS: the things you OPEN, as opposed to the things you do to a window once
-- it is open. The distinction is the whole course, so it is worth pinning: a
-- course that quietly swallowed window operations would mean nothing.
local appbank = {
  { combo = "SUPER + RETURN", modmask = 64, description = "Terminal" },
  { combo = "SUPER + B",      modmask = 64, description = "Browser" },
  { combo = "SUPER + SHIFT + O", modmask = 65, description = "Obsidian" },
  { combo = "SUPER + N",      modmask = 64, description = "New email" },
  { combo = "SUPER + W",      modmask = 64, description = "Close window" },
  { combo = "SUPER + 1",      modmask = 64, description = "Switch to workspace 1" },
  { combo = "SUPER + ALT + R",modmask = 72, description = "Set reminder" },
  { combo = "SUPER + T",      modmask = 64, description = "Show time" },
}
local apps = core.filter_course(appbank, "apps")
local picked = {}
for _, e in ipairs(apps) do picked[e.description] = true end
truthy("apps picks up a terminal",   picked["Terminal"])
truthy("apps picks up a browser",    picked["Browser"])
truthy("apps picks up an app by name", picked["Obsidian"])
truthy("apps picks up composing mail", picked["New email"])
-- The exclusions ARE the course. Anything that operates on a window belongs to
-- another course, and a one-shot action is something you DO, not something you
-- open: mixing those in would make "apps" mean nothing in particular.
eq("apps excludes window operations", nil, picked["Close window"])
eq("apps excludes workspaces",        nil, picked["Switch to workspace 1"])
eq("apps excludes one-shot actions",  nil, picked["Set reminder"])
eq("apps excludes readouts",          nil, picked["Show time"])

-- System panels launch exactly like apps and are deliberately NOT in this
-- course: you do not work in them, and you reach for them rarely. An app you
-- open twenty times a day and a panel you open twice a month are not the same
-- drill. They live in Endurance with the other far corners, and the pairing
-- below is asserted in both directions so dropping one never orphans it.
local panelbank = {
  { combo = "SUPER + CTRL + B", modmask = 68, description = "Bluetooth" },
  { combo = "SUPER + CTRL + W", modmask = 68, description = "Network" },
  { combo = "SUPER + CTRL + D", modmask = 68, description = "Display" },
  { combo = "SUPER + CTRL + T", modmask = 68, description = "Activity" },
}
local in_apps = core.filter_course(panelbank, "apps")
eq("apps holds no system panels", 0, #in_apps)

local in_endurance = {}
for _, e in ipairs(core.filter_course(panelbank, "endurance")) do
  in_endurance[e.description] = true
end
for _, d in ipairs({ "Bluetooth", "Network", "Display", "Activity" }) do
  truthy(("endurance drills %s"):format(d), in_endurance[d])
end

-- All four curated tiers ship now. Track Day and Endurance were specified from
-- the start and simply never built, which left two trophies depending on a
-- course that did not exist.
local CURATED = { "daily-driver", "the-commute", "track-day", "endurance", "apps",
                  "system", "service-park" }
for _, name in ipairs(CURATED) do
  truthy(("%s is a real course"):format(name), core.COURSES[name] ~= nil)
  truthy(("%s has patterns"):format(name), #(core.COURSES[name].patterns or {}) > 0)
  truthy(("%s explains itself"):format(name), (core.COURSES[name].note or "") ~= "")
end

-- --- coverage ----------------------------------------------------------------
-- THE COURSES TOGETHER MUST COVER THE KEYMAP, or the game quietly stops
-- teaching whole regions of it. That is not hypothetical: 53 bindings, a quarter
-- of the map, had drifted out of every course before anyone counted, reachable
-- only with `--all`. They were the least discoverable things on the machine,
-- which is exactly what a trainer is for.
--
-- Anything genuinely not worth drilling goes on M.UNCOURSED with a reason, so an
-- exclusion is a decision somebody wrote down rather than an accident nobody
-- noticed.
do
  local full = dofile((arg[0]:match("(.*/)") or "./") .. "fixtures/inventory.lua")
  local covered = {}
  for _, name in ipairs(core.course_names()) do
    -- Blind Spots is generated from history, so it covers nothing by itself.
    if name ~= "blind-spots" then
      for _, e in ipairs(core.filter_course(full, name, "")) do
        covered[e.description] = true
      end
    end
  end

  local missed, seen = {}, {}
  for _, e in ipairs(full) do
    local d = e.description
    if not covered[d] and not core.is_uncoursed(d) and not seen[d] then
      seen[d] = true
      missed[#missed + 1] = d
    end
  end
  if #missed == 0 then
    ok("every binding is in a course or deliberately excluded")
  else
    fail("every binding is in a course or deliberately excluded", "none missed",
         ("%d with no home: %s"):format(#missed, table.concat(missed, ", ")))
  end

  -- And the other direction: an allow-list entry that matches nothing is a rule
  -- about a binding that no longer exists, which is how a stale exclusion hides
  -- a real gap.
  local dead = {}
  for _, pat in ipairs(core.UNCOURSED) do
    local hit = false
    for _, e in ipairs(full) do
      if core.safe_match(e.description, pat) then hit = true break end
    end
    if not hit then dead[#dead + 1] = pat end
  end
  eq("no exclusion is stale", 0, #dead)

  -- An exclusion must never swallow something a course wants. If both claim a
  -- binding, one of them is wrong and it is worth knowing which.
  local both = {}
  for d in pairs(covered) do
    if core.is_uncoursed(d) then both[#both + 1] = d end
  end
  eq("nothing is both covered and excluded", 0, #both)
end

-- SERVICE PARK exists so nothing is written off. Its whole justification is
-- that the exclusion list is empty, so if a binding ever falls out of every
-- course again the coverage assertion above fails rather than someone quietly
-- adding a pattern here.
eq("nothing is excluded from every course", 0, #core.UNCOURSED)
truthy("service park has the odd-shaped keys",
       #core.filter_course({
         { combo = "SUPER + CTRL + 1", modmask = 68, description = "Bar panel 1" },
         { combo = "SUPER + CTRL + T", modmask = 68, description = "Show time" },
       }, "service-park") == 2)

-- --- scenery -----------------------------------------------------------------
-- Each course wears an Omarchy theme background. The mapping is data, so it is
-- worth asserting it is COMPLETE rather than trusting that whoever adds the next
-- course remembers: a course with no scene falls back to the default, which
-- looks fine and quietly means the course never got one.
for _, name in ipairs(core.course_names()) do
  local sc = core.scene_for(name)
  truthy(("%s has a scene"):format(name), sc ~= nil)
  truthy(("%s names a theme"):format(name), (sc.theme or "") ~= "")
  truthy(("%s names a file"):format(name), (sc.file or "") ~= "")
  -- The scrim is what keeps the words readable over the picture. Zero would
  -- mean no dimming at all, which is how a screen becomes unreadable.
  truthy(("%s dims its backdrop"):format(name), (sc.scrim or 0) > 0 and sc.scrim < 1)
end

-- Every course got its OWN scene rather than silently inheriting the default.
local defaults = 0
for _, name in ipairs(core.course_names()) do
  if core.scene_for(name) == core.DEFAULT_SCENE then defaults = defaults + 1 end
end
eq("no course silently falls back to the default scene", 0, defaults)

-- And the fallbacks that should fall back, do.
truthy("no course at all gets the default", core.scene_for(nil) == core.DEFAULT_SCENE)
truthy("an unknown course gets the default", core.scene_for("nonsense") == core.DEFAULT_SCENE)

-- The bright ones need heavier dimming than the dark ones. This is the whole
-- reason the scrim is per course rather than one number: a Brueghel and a black
-- moon cannot share a value.
truthy("the busiest backdrop is dimmed hardest",
       core.scene_for("the-commute").scrim > core.scene_for("endurance").scrim)

-- No course may be modifier-homogeneous. Grouping by modmask leaks the answer:
-- the player pre-loads the modifiers and only reaction-times the key, which
-- trains half the skill. A course built by hand can fail this by accident.
local wide = {
  { combo = "SUPER + T",             modmask = 64, description = "Toggle window grouping" },
  { combo = "SUPER + SHIFT + T",     modmask = 65, description = "Toggle window split" },
  { combo = "SUPER + CTRL + V",      modmask = 68, description = "Clipboard manager" },
  { combo = "SUPER + ALT + P",       modmask = 72, description = "Color picker" },
  { combo = "XF86AudioRaiseVolume",  modmask = 0,  description = "Volume up precise" },
  { combo = "SUPER + SHIFT + 7",     modmask = 65, description = "Move window to workspace 7" },
  { combo = "SUPER + 7",             modmask = 64, description = "Switch to workspace 7" },
  { combo = "SUPER + CTRL + R",      modmask = 68, description = "Screenrecording" },
}
for _, name in ipairs({ "track-day", "endurance" }) do
  local pool = core.filter_course(wide, name)
  local masks = {}
  local n = 0
  for _, e in ipairs(pool) do
    if not masks[e.modmask] then masks[e.modmask] = true; n = n + 1 end
  end
  truthy(("%s draws from more than one modifier set"):format(name), n > 1)
end

-- Courses match on DESCRIPTION, not combo, so a remapped key keeps its tier.
local remapped = { { combo = "CTRL + ALT + T", modmask = 12, description = "Terminal" } }
eq("a remapped binding keeps its course", 1, #core.filter_course(remapped, "daily-driver"))

-- An unknown course name must not silently yield an empty stage.
eq("unknown course falls back to the full bank", #bank, #core.filter_course(bank, "nope"))

-- --- whole runs ------------------------------------------------------------
-- The Cabinet needs stages kept apart, because a trophy is earned by a run
-- rather than by an answer. parse_history deliberately flattens; this does not.
local runs_text = table.concat({
  '{"stamp":"2026-08-24T10:00:00","course":"daily-driver","difficulty":"hard","prompts":2,' ..
  '"correct":2,"offs":0,"average_ms":1500,"assisted":false,"completed":true,"clean":true,"requeues":0,' ..
  '"answers":[{"combo":"A","description":"One","outcome":"correct","reaction_ms":900},' ..
  '{"combo":"B","description":"Two","outcome":"correct","reaction_ms":1100}]}',
  '{"stamp":"2026-08-25T10:00:00","course":"the-commute","prompts":1,"correct":0,"offs":1,' ..
  '"average_ms":null,"assisted":true,"completed":false,"clean":false,"requeues":0,' ..
  '"answers":[{"combo":"C","description":"Three","outcome":"off","reaction_ms":2000}]}',
}, "\n")
local runs = core.parse_runs(runs_text)
eq("two runs are read", 2, #runs)
eq("a run keeps its answers together", 2, #runs[1].answers)
eq("a run keeps its course", "daily-driver", runs[1].course)
eq("a run keeps its difficulty", "hard", runs[1].difficulty)
eq("stage booleans survive", true, runs[1].completed)
eq("the second run is separate", 1, #runs[2].answers)
eq("runs stay in play order", "2026-08-25T10:00:00", runs[2].stamp)

eq("previously missed collects only misses", true, core.previously_missed(runs_text)["Three"])
eq("a correct answer is not a miss", nil, core.previously_missed(runs_text)["One"])
-- Only COMPLETED runs are a time to beat: a retired stage's average is over
-- whatever happened to be answered before walking away.
eq("best course average uses completed runs", 1500, core.best_course_average(runs_text, "daily-driver"))
eq("an unfinished run sets no time to beat", nil, core.best_course_average(runs_text, "the-commute"))
eq("a course never played has no average", nil, core.best_course_average(runs_text, "endurance"))

-- --- the ghost -------------------------------------------------------------
-- Personal bests come ONLY from unassisted stages. A hinted answer is a time
-- the player never actually drove, and a ghost built from hints would have them
-- chasing the co-driver rather than themselves.
local function ghost_stage(assisted, answers)
  local parts = {}
  for _, a in ipairs(answers) do
    parts[#parts + 1] = ('{"combo":"%s","description":"%s","outcome":"%s","pressed":"Y","reaction_ms":%s}')
      :format(a[4] or "SUPER + Z", a[1], a[2], tostring(a[3]))
  end
  return ('{"course":"all","assisted":%s,"answers":[%s]}')
    :format(tostring(assisted), table.concat(parts, ","))
end

local gh = table.concat({
  ghost_stage(false, { { "Browser", "correct", 1500, "SUPER + SHIFT + B" } }),
  ghost_stage(false, { { "Browser", "correct", 1200, "SUPER + SHIFT + B" } }),
  ghost_stage(true,  { { "Browser", "correct", 400,  "SUPER + SHIFT + B" } }),  -- hinted
  ghost_stage(false, { { "Terminal", "off", 900, "SUPER + RETURN" } }),          -- a miss
  ghost_stage(false, { { "Slowpoke", "correct", 45000, "SUPER + P" } }),         -- away
}, "\n")
local bests = core.personal_bests(gh)
eq("the best unassisted time wins", 1200, bests["Browser"])
eq("an assisted stage cannot set a best", 1200, bests["Browser"])
eq("a miss sets no best", nil, bests["Terminal"])
eq("an away-outlier sets no best", nil, bests["Slowpoke"])
-- Same identity/evidence rule as Blind Spots: a best on a combo you remapped
-- away is a fact about a keystroke you no longer have.
eq("a best on a remapped combo is dropped", nil,
   core.personal_bests(gh, { combos = { ["Browser"] = { ["CTRL + ALT + W"] = true } } })["Browser"])
eq("a best on a still-bound combo survives", 1200,
   core.personal_bests(gh, { combos = { ["Browser"] = { ["SUPER + SHIFT + B"] = true } } })["Browser"])

-- The delta must reach the result, and be signed the way a driver reads it.
local ginv = { { combo = "SUPER + X", modmask = 64, description = "Universal cut" } }
local function raced(reaction, assisted)
  local st = core.new_stage(ginv, { length = 1, seed = 1, ghost = { ["Universal cut"] = 1000 } })
  st.assisted = assisted or false
  local pr = core.next_prompt(st, 0)
  return core.answer(st, pr.combo, reaction), core.summary(st)
end
local ahead = raced(700)
eq("beating the ghost reads negative", -300, ahead.ghost_delta)
eq("beating the ghost is a personal best", true, ahead.best)
local behind = raced(1400)
eq("losing to the ghost reads positive", 400, behind.ghost_delta)
eq("losing to the ghost is not a best", nil, behind.best)
-- The co-driver disqualifies the run from setting one, per the design.
eq("a hinted answer cannot be a best", nil, raced(700, true).best)
-- A note with no ghost is not announced as a best: on a new player every note
-- would be, and a banner that always fires means nothing.
local unseen = core.new_stage(ginv, { length = 1, seed = 1, ghost = {} })
local up = core.next_prompt(unseen, 0)
local ur = core.answer(unseen, up.combo, 500)
eq("a note with no ghost has no delta", nil, ur.ghost_delta)
eq("a note with no ghost is not a best", nil, ur.best)

local _, gsum = raced(700)
eq("the summary counts ghosted notes", 1, gsum.ghost_notes)
eq("the summary counts notes beaten", 1, gsum.ghost_beat)
eq("the summary nets the delta", -300, gsum.ghost_delta)
eq("no ghosted notes means no stage delta", nil, core.summary(unseen).ghost_delta)

-- --- the history record ----------------------------------------------------
-- The mode has to be ON the record. Cross-run numbers (averages, bests, the
-- ghost) are meaningless if they silently mix ladders.
local rec_stage = core.new_stage(inv, { length = 2, seed = 1, course = "daily-driver",
                                        difficulty = "hard", tier_scale = 0.7 })
local rp = core.next_prompt(rec_stage, 0)
core.answer(rec_stage, rp.combo, 900)
local line = core.history_record(rec_stage, { stamp = "S" })
truthy("the record names its difficulty", line:find('"difficulty":"hard"', 1, true) ~= nil)
truthy("the record names its course",     line:find('"course":"daily-driver"', 1, true) ~= nil)
local plain = core.history_record(core.new_stage(inv, { length = 1, seed = 1 }), {})
truthy("a stage with no mode records the default",
  plain:find('"difficulty":"medium"', 1, true) ~= nil)

-- --- the JSON encoder -------------------------------------------------------
-- history.jsonl is hand-built because its shape is fixed. The screen state is
-- not: it differs per screen and will keep changing as the display grows, so it
-- gets a real encoder rather than a dozen more bespoke concatenations.
eq("nil is null",        "null",  core.to_json(nil))
eq("true",               "true",  core.to_json(true))
eq("false",              "false", core.to_json(false))
eq("an integer has no decimal point", "7", core.to_json(7))
eq("a float keeps precision", "0.25", core.to_json(0.25))
eq("a negative number",  "-3",    core.to_json(-3))
-- A display divides by counts; a NaN or infinity reaching the file would break
-- the consumer rather than this encoder, so it is neutralised here.
eq("NaN becomes null",      "null", core.to_json(0/0))
eq("infinity becomes null", "null", core.to_json(math.huge))
eq("a string is escaped", '"he said \\"hi\\""', core.to_json('he said "hi"'))
eq("an array",           '[1,2,3]', core.to_json({1,2,3}))
eq("an array of strings", '["a","b"]', core.to_json({"a","b"}))
eq("a nested object", '{"a":{"b":1}}', core.to_json({ a = { b = 1 } }))
-- An empty Lua table is genuinely ambiguous; [] is the conventional choice.
eq("an empty table is an array", "[]", core.to_json({}))

-- Keys are SORTED. The state file is rewritten many times a second and read by
-- a file watcher, so an unchanged screen must produce an identical file.
eq("object keys are sorted", '{"a":1,"b":2,"c":3}', core.to_json({ c=3, a=1, b=2 }))
eq("the same table always encodes the same",
   core.to_json({ z=1, y=2, x=3 }), core.to_json({ x=3, y=2, z=1 }))

-- The shape a display actually consumes, round-tripped through the reader that
-- already exists, so the two halves of the JSON story are checked against each
-- other rather than each against itself.
local doc = core.to_json({
  screen = "prompt",
  stage = { index = 3, total = 10, gear = 2, points = 165, assisted = true },
  held = { SUPER = true, ALT = false },
})
truthy("the document names its screen", doc:find('"screen":"prompt"', 1, true) ~= nil)
truthy("booleans survive", doc:find('"assisted":true', 1, true) ~= nil)
truthy("false is not dropped", doc:find('"ALT":false', 1, true) ~= nil)

-- --- history parsing -------------------------------------------------------
-- The reader is escape-aware on purpose. A naive '"description":"([^"]*)"'
-- match truncates on the first escaped quote and then mis-attributes every
-- later field on the line -- a silent wrong answer, which is why this is tested
-- against nastier input than the game will ever write.
local hist_line = '{"stamp":"s","course":"daily-driver","prompts":2,"answers":[' ..
  '{"combo":"A","description":"He said \\"hi\\"","outcome":"off","pressed":"B","reaction_ms":900},' ..
  '{"combo":"C","description":"Brace } and \\\\ slash","outcome":"correct","reaction_ms":null}]}'
local parsed = core.parse_history(hist_line)
eq("both answers are read",              2,  #parsed)
eq("an escaped quote survives",          'He said "hi"', parsed[1].description)
eq("outcome is read past the quotes",    "off", parsed[1].outcome)
eq("reaction_ms becomes a number",       900, parsed[1].reaction_ms)
eq("a brace inside a string does not close the object", "Brace } and \\ slash", parsed[2].description)
eq("null reaction_ms is nil, not zero",  nil, parsed[2].reaction_ms)

-- The stage-level fields carry a "course" key of their own. Scanning the whole
-- line instead of just the answers array would read it as an answer.
eq("stage-level fields are not answers", 2, #core.parse_history(hist_line))

eq("no history parses to nothing",       0, #core.parse_history(""))
eq("nil history parses to nothing",      0, #core.parse_history(nil))
eq("a malformed line is skipped",        0, #core.parse_history("not json at all"))
eq("an empty answers array is fine",     0, #core.parse_history('{"answers":[]}'))
eq("blank lines between records are skipped", 2,
   #core.parse_history(hist_line .. "\n\n" .. '{"answers":[]}' .. "\n"))

-- --- blind spots -----------------------------------------------------------
-- { description, outcome, reaction_ms, combo }. The combo matters: evidence is
-- keyed on it, so a fixture with a placeholder combo reads as stale history.
local function stage_json(answers)
  local parts = {}
  for _, a in ipairs(answers) do
    parts[#parts + 1] = ('{"combo":"%s","description":"%s","outcome":"%s","pressed":"Y","reaction_ms":%s}')
      :format(a[4] or "SUPER + Z", a[1], a[2], a[3] and tostring(a[3]) or "null")
  end
  return '{"course":"all","answers":[' .. table.concat(parts, ",") .. "]}"
end

local BROWSER_KEY, SYSMENU_KEY = "SUPER + SHIFT + B", "SUPER + ESCAPE"
local h = table.concat({
  stage_json { { "Browser", "off", 1000, BROWSER_KEY }, { "Terminal", "correct", 500, "SUPER + RETURN" }, { "Noise", "off", 800 } },
  stage_json { { "Browser", "off", 1200, BROWSER_KEY }, { "Terminal", "correct", 600, "SUPER + RETURN" } },
  stage_json { { "Browser", "correct", 900, BROWSER_KEY }, { "System menu", "correct", 8000, SYSMENU_KEY } },
}, "\n")

local spots = core.blind_spots(h)
local by_description = {}
for i, r in ipairs(spots) do by_description[r.description] = { rank = i, row = r } end

eq("a binding missed twice is a blind spot", "missed", by_description["Browser"].row.reason)
eq("miss count is carried",                  2, by_description["Browser"].row.misses)
eq("times seen is carried",                  3, by_description["Browser"].row.seen)
-- One miss is noise. Promoting it would fill the course with flukes.
eq("a binding missed once is not a blind spot", nil, by_description["Noise"])
-- Right but slow is a weakness one notch down, and it is what tops the course
-- up when the player has few outright misses.
eq("slow-when-correct tops up the course",   "slow", by_description["System menu"].row.reason)
truthy("misses outrank hesitations",         by_description["Browser"].rank < by_description["System menu"].rank)
eq("fast and correct is not a blind spot",   nil, by_description["Terminal"])

-- An away-outlier is not thinking time. omashift-stats uses the same cutoff.
local away = core.blind_spots(stage_json { { "Wandered", "correct", 45000 } })
eq("a 45s answer is discarded, not called slow", 0, #away)

-- Same history in, same course out -- a stage has to be reproducible from its
-- seed, and an unstable sort would break that.
local a1, a2 = core.blind_spots(h), core.blind_spots(h)
local ranking_same = #a1 == #a2
for i = 1, #a1 do
  if a1[i].description ~= a2[i].description then ranking_same = false end
end
truthy("ranking is deterministic", ranking_same)

-- --- the blind-spots course ------------------------------------------------
-- Two combos, one description: Omarchy really does this ("Browser" is both
-- SUPER+SHIFT+RETURN and SUPER+SHIFT+B), and dedupe_by_action needs both to
-- offer them as alternates.
local bs_bank = {
  { combo = "SUPER + SHIFT + RETURN", modmask = 65, description = "Browser" },
  { combo = "SUPER + SHIFT + B",      modmask = 65, description = "Browser" },
  { combo = "SUPER + ESCAPE",         modmask = 64, description = "System menu" },
  { combo = "SUPER + RETURN",         modmask = 64, description = "Terminal" },
}
local bs = core.filter_course(bs_bank, "blind-spots", h)
eq("the course is built from history",   3, #bs)
eq("worst first",                        "Browser", bs[1].description)
eq("alternate combos are both kept",     "Browser", bs[2].description)
eq("a clean binding is excluded",        "System menu", bs[3].description)

-- A blind spot the player has since remapped away is gone from the inventory.
-- Prompting for a combo that no longer works would be a bug, not a drill.
local remapped_away = { { combo = "SUPER + ESCAPE", modmask = 64, description = "System menu" } }
eq("a remapped-away blind spot is dropped", 1, #core.filter_course(remapped_away, "blind-spots", h))

-- --- identity is the description, evidence is the combo ---------------------
-- Grouping stays per-description so a remap keeps its course tier and an action
-- with two aliases stays ONE prompt. But whether the player can execute it is a
-- fact about a keystroke, so a miss recorded against a combo the action no
-- longer has must not keep it in the course.
local moved = {
  { combo = "CTRL + ALT + W", modmask = 12, description = "Browser" },
  { combo = "SUPER + ESCAPE", modmask = 64, description = "System menu" },
}
local after_remap = {}
for _, r in ipairs(core.blind_spots(h, { combos = { ["Browser"] = { ["CTRL + ALT + W"] = true } } })) do
  after_remap[r.description] = r
end
eq("misses on a combo since remapped are discarded", nil, after_remap["Browser"])
eq("a remapped Browser is out of the course", 1, #core.filter_course(moved, "blind-spots", h))

-- The other half of the same rule: an alias that is STILL bound keeps its
-- history. Dropping evidence on a remap of a sibling combo would be wrong.
local kept = core.filter_course({
  { combo = "SUPER + SHIFT + B",      modmask = 65, description = "Browser" },
  { combo = "SUPER + SHIFT + RETURN", modmask = 65, description = "Browser" },
}, "blind-spots", h)
eq("history survives while its combo is still bound", 2, #kept)

-- A description gone from the inventory entirely is left alone here and dropped
-- by the filter instead -- silently rewriting history would be worse.
truthy("an unknown description is not treated as stale",
  (function()
    for _, r in ipairs(core.blind_spots(h, { combos = { ["Terminal"] = {} } })) do
      if r.description == "Browser" then return true end
    end
    return false
  end)())

-- With no history there is nothing to drill. Returning the full bank here would
-- silently hand a first-time player all 195 bindings; the caller decides.
eq("no history yields an empty course",  0, #core.filter_course(bs_bank, "blind-spots", ""))

-- The curated tiers must not care that the argument exists.
eq("a static course ignores history", #core.filter_course(bank, "daily-driver"),
   #core.filter_course(bank, "daily-driver", h))

truthy("blind-spots is listed as a course", (function()
  for _, n in ipairs(core.course_names()) do if n == "blind-spots" then return true end end
  return false
end)())

-- --- user-defined courses --------------------------------------------------
-- The shipped tiers are one person's judgment, and a newcomer cannot see what
-- is MISSING from them. Every rejection below is a config-file typo that would
-- otherwise fail silently or, worse, hand the player the whole 200-binding bank.
local n, probs = core.merge_courses({
  ["mine"]        = { label = "Mine", patterns = { "^Terminal$", "^Browser$" } },
  ["no-patterns"] = { label = "Empty" },
  ["empty-list"]  = { patterns = {} },
  ["not-a-table"] = "nope",
  ["blind-spots"] = { patterns = { "^x$" } },
  [""]            = { patterns = { "^y$" } },
  ["nonstring"]   = { patterns = { 42 } },
})
eq("only the valid course is merged", 1, n)
eq("six bad definitions are reported", 6, #probs)
truthy("a valid user course is selectable", core.COURSES["mine"] ~= nil)
eq("a user course keeps its label", "Mine", core.course_label("mine"))
eq("a course with no patterns is refused", nil, core.COURSES["no-patterns"])
eq("an empty pattern list is refused",     nil, core.COURSES["empty-list"])
eq("a non-table course is refused",        nil, core.COURSES["not-a-table"])
eq("a non-string pattern is refused",      nil, core.COURSES["nonstring"])
-- Blind Spots computes its entries; a pattern list cannot express it, so
-- letting someone redefine it would quietly turn it into a static course.
truthy("a generated course cannot be redefined", core.COURSES["blind-spots"].dynamic == true)
eq("a non-table argument is reported", 1, select(2, core.merge_courses("nope")) and
   #select(2, core.merge_courses("nope")) or 0)

-- Lua validates patterns LAZILY -- "^(unclosed" raises only once a match
-- engages -- so validation cannot be complete and matching must be safe. A bad
-- pattern costs the entries it would have matched, never the stage.
core.merge_courses({ ["poisoned"] = { patterns = { "^(unclosed", "^Terminal$" } } })
local poison_bank = {
  { combo = "SUPER + U", modmask = 64, description = "unclosed" },
  { combo = "SUPER + RETURN", modmask = 64, description = "Terminal" },
}
local ok_filter, filtered = pcall(core.filter_course, poison_bank, "poisoned")
truthy("a poisoned pattern does not crash the filter", ok_filter)
eq("the poisoned pattern matches nothing", 1, #filtered)
eq("the sound pattern in the same course still works", "Terminal", filtered[1].description)
eq("safe_match reports no match rather than raising", false,
   core.safe_match("unclosed", "^(unclosed"))

-- CLEAN UP AFTER IT. merge_courses writes into core.COURSES for the rest of the
-- run, so this test was leaving a course called "poisoned" in the shipped set,
-- and every later test that walks the course table saw it. Nothing failed, but
-- the ordering test below was quietly running against a table this file had
-- vandalised, which is not the table the game has.
core.COURSES["poisoned"] = nil

eq("safe_match still matches normally", true, core.safe_match("Terminal", "^Terminal$"))

-- --- a course you write brings its own backdrop -----------------------------
-- Every shipped course wears a theme background and a user course could not
-- name one, so it fell through to DEFAULT_SCENE: the course somebody plays
-- every day opened on the same picture as no course at all.
local scened, scene_probs = core.merge_courses({
  ["with-scene"]   = { patterns = { "^Terminal$" },
                       scene = { theme = "retro-82", file = "4-gateway.jpg", scrim = 0.58 } },
  ["no-scrim"]     = { patterns = { "^Terminal$" }, scene = { theme = "nord", file = "x.jpg" } },
  ["scene-string"] = { patterns = { "^Terminal$" }, scene = "retro-82" },
  ["no-theme"]     = { patterns = { "^Terminal$" }, scene = { file = "4-gateway.jpg" } },
  ["no-file"]      = { patterns = { "^Terminal$" }, scene = { theme = "retro-82" } },
  ["black-scrim"]  = { patterns = { "^Terminal$" },
                       scene = { theme = "retro-82", file = "4-gateway.jpg", scrim = 1 } },
})
eq("every one of them is still a course", 6, scened)
eq("a user course keeps its theme", "retro-82", core.scene_for("with-scene").theme)
eq("and its file",  "4-gateway.jpg", core.scene_for("with-scene").file)
eq("and its scrim", 0.58,            core.scene_for("with-scene").scrim)
-- A backdrop with no dimming is a screen you cannot read, so an omitted scrim
-- takes the default rather than zero.
eq("an omitted scrim takes the default", core.DEFAULT_SCENE.scrim, core.scene_for("no-scrim").scrim)
-- A MALFORMED BACKDROP COSTS THE PICTURE, NOT THE COURSE. Patterns are what a
-- drill is and are refused out loud; dimming is decoration.
eq("four bad backdrops are reported", 4, #scene_probs)
for _, name in ipairs({ "scene-string", "no-theme", "no-file", "black-scrim" }) do
  truthy(("%s is still playable"):format(name), core.COURSES[name] ~= nil)
  truthy(("%s falls back to the default backdrop"):format(name),
         core.scene_for(name) == core.DEFAULT_SCENE)
end
-- Clean up, like the poisoned course above: merge_courses writes into
-- core.COURSES for the rest of the run, and later tests walk that table.
for _, name in ipairs({ "with-scene", "no-scrim", "scene-string", "no-theme", "no-file",
                        "black-scrim", "mine" }) do
  core.COURSES[name] = nil
end

-- --- reading the courses file ----------------------------------------------
--
-- REGRESSION: a course written in courses.lua was listed by `omashift --courses`
-- and by the menu, and `C` cycled straight past it. --cycle-course asked a fresh
-- Lua state for core.course_names() and never read the file, so the one course
-- the escape hatch exists to add was the one course nobody could select.
--
-- The wiring assertion covering that line passed the whole time: it checked the
-- list was ASKED FOR rather than hardcoded, which was true. And the ordering
-- test above writes into core.COURSES directly, so it never touched the file
-- either. Nothing here was under-tested; the two tests met in the wrong place.
--
-- This is the only block in this file that touches the filesystem, and it does
-- so because reading the file IS the thing that broke.
do
  local cf = require("courses-file")
  local path = os.tmpname()
  local f = assert(io.open(path, "w"))
  f:write('return { ["from-file"] = { label = "From File", patterns = { "^Terminal$" } } }\n')
  f:close()

  local added, problems = cf.merge(core, path)
  os.remove(path)
  eq("a course is merged from the file", 1, added)
  eq("with nothing to complain about", 0, #problems)
  truthy("and it is selectable", core.COURSES["from-file"] ~= nil)

  -- The whole bug, as one assertion: listed and reachable are the same list.
  local names, found = core.course_names(), false
  for _, n2 in ipairs(names) do if n2 == "from-file" then found = true end end
  truthy("a course from the file reaches the cycle", found)
  core.COURSES["from-file"] = nil

  -- Absent is the common case and is not a problem. Returning a complaint here
  -- would put "courses file failed to load" in front of everyone who never
  -- wrote one.
  local a2, p2 = cf.merge(core, path .. "-does-not-exist")
  eq("a missing file merges nothing", 0, a2)
  eq("and says nothing about it", 0, #p2)

  -- A syntax error costs the custom courses, never the game.
  local bad = os.tmpname()
  local bf = assert(io.open(bad, "w"))
  bf:write("return { this is not lua\n")
  bf:close()
  local a3, p3 = cf.merge(core, bad)
  os.remove(bad)
  eq("a broken file merges nothing", 0, a3)
  eq("and reports exactly one problem", 1, #p3)
  truthy("naming the file as the cause", p3[1]:match("failed to load") ~= nil)

  truthy("the path follows XDG", cf.path():match("/omashift/courses%.lua$") ~= nil)
end

-- --- co-driver -------------------------------------------------------------
local note = { combo = "SUPER + SHIFT + B", description = "Browser" }
eq("no hint before the first threshold", nil, core.hint_for(note, 500))
eq("modifiers revealed at 2s", "mods", core.hint_for(note, 2000).level)
eq("modifier hint hides the key", "SUPER + SHIFT + ?", core.hint_for(note, 2000).text)
eq("full combo revealed later", "full", core.hint_for(note, 5000).level)
eq("full hint is the whole combo", "SUPER + SHIFT + B", core.hint_for(note, 5000).text)
-- A single-modifier combo must still hide its key rather than leaking it.
local simple = { combo = "SUPER + W", description = "Close window" }
eq("single-modifier hint still hides the key", "SUPER + ?", core.hint_for(simple, 2000).text)
eq("nil elapsed yields no hint", nil, core.hint_for(note, nil))

-- Co-driver timing is configurable; a feel decision must not be a constant.
eq("custom mods threshold is respected", nil, core.hint_for(note, 2500, { mods_ms = 4000 }))
eq("custom mods threshold fires when reached", "mods",
   core.hint_for(note, 4000, { mods_ms = 4000 }).level)
eq("custom full threshold is respected", "mods",
   core.hint_for(note, 5000, { mods_ms = 4000, full_ms = 8000 }).level)
eq("missing opts fall back to defaults", "mods", core.hint_for(note, 2000, {}).level)
-- A full threshold below the mods threshold would reveal the answer before the
-- hint, so it is clamped rather than trusted.
local m, f = core.codriver_timing({ mods_ms = 5000, full_ms = 1000 })
eq("full threshold clamps to at least mods", 5000, f)
eq("and clamping it leaves the mods threshold alone", 5000, m)
eq("negative thresholds clamp to zero", 0, (core.codriver_timing({ mods_ms = -1 })))

-- --- equivalent bindings ---------------------------------------------------
-- REGRESSION: Omarchy describes more than one combo identically. "Browser" is
-- both SUPER+SHIFT+RETURN and SUPER+SHIFT+B. Demanding one specific combo marks
-- a genuinely correct answer wrong; a real playtest lost three prompts in a row
-- to this, and requeue kept handing the unwinnable note back.
local dual = {
  { combo = "SUPER + SHIFT + B",      modmask = 65, description = "Browser" },
  { combo = "SUPER + SHIFT + RETURN", modmask = 65, description = "Browser" },
}
local dstage = core.new_stage(dual, { length = 1, seed = 1 })
local dp = core.next_prompt(dstage, 0)
local other = (dp.combo == dual[1].combo) and dual[2] or dual[1]
eq("REGRESSION: an equivalent binding counts as correct", "correct",
   core.answer(dstage, other.combo, 400, other.description).outcome)

-- A different action must still be wrong even when it is a real binding.
local wstage = core.new_stage(dual, { length = 1, seed = 1 })
core.next_prompt(wstage, 0)
eq("a genuinely different binding is still an off", "off",
   core.answer(wstage, "SUPER + W", 400, "Close window").outcome)
-- An unknown combo has no description and must not be treated as equivalent.
local ustage = core.new_stage(dual, { length = 1, seed = 1 })
core.next_prompt(ustage, 0)
eq("an unknown combo is an off", "off",
   core.answer(ustage, "SUPER + ZZZ", 400, nil).outcome)

-- --- requeue accounting ----------------------------------------------------
-- Requeued misses grow the prompt list, so the summary must distinguish the
-- original length or it reads like a miscount ("6 / 9" for a 6-note stage).
local rstage = core.new_stage(bank, { length = 3, seed = 4 })
eq("a fresh stage records its base length", 3, rstage.base_length)
core.next_prompt(rstage, 0)
core.requeue(rstage, core.current(rstage), 1)
local rsum = core.summary(rstage)
eq("summary reports the original length", 3, rsum.base_prompts)
eq("summary counts requeues separately", 1, rsum.requeues)

-- --- one prompt per action -------------------------------------------------
-- REGRESSION: Omarchy describes several combos identically, so the bank held
-- two "Browser" entries and a stage could ask the same action twice. That reads
-- as a bug even when both answers are accepted.
local dupbank = {
  { combo = "SUPER + SHIFT + B",      modmask = 65, description = "Browser" },
  { combo = "SUPER + SHIFT + RETURN", modmask = 65, description = "Browser" },
  { combo = "SUPER + W",              modmask = 64, description = "Close window" },
}
local collapsed = core.dedupe_by_action(dupbank)
eq("REGRESSION: one entry per action", 2, #collapsed)
local browser
for _, e in ipairs(collapsed) do if e.description == "Browser" then browser = e end end
truthy("the collapsed entry keeps its alternates", browser.alts ~= nil)
eq("the alternate combo is preserved", "SUPER + SHIFT + RETURN", browser.alts[1])
eq("a unique action gains no alternates", nil,
   (function() for _, e in ipairs(collapsed) do
      if e.description == "Close window" then return e.alts end end end)())
-- A stage must never ask the same action twice.
local dstage2 = core.new_stage(dupbank, { length = 3, seed = 1 })
local seen_desc, dupes = {}, 0
for _, pr in ipairs(dstage2.prompts) do
  if seen_desc[pr.description] then dupes = dupes + 1 end
  seen_desc[pr.description] = true
end
eq("a stage never repeats an action", 0, dupes)

-- --- away outliers ---------------------------------------------------------
-- A 4-minute "reaction" is an interruption, not thinking: the co-driver has
-- revealed the whole combo by ~8s. One such answer dragged a real stage average
-- from ~2s to 42s, making the number meaningless.
local astage2 = core.new_stage(bank, { length = 2, seed = 1 })
core.next_prompt(astage2, 0)
core.answer(astage2, core.current(astage2).combo, 239870)
core.next_prompt(astage2, 0)
core.answer(astage2, core.current(astage2).combo, 1500)
local asum = core.summary(astage2)
eq("an away answer is excluded from the average", 1500.0, asum.average_ms)
eq("away answers are counted separately", 1, asum.away)
eq("an away answer still counts as correct", 2, asum.correct)
-- The boundary must not silently drop ordinary slow answers.
local bstage = core.new_stage(bank, { length = 1, seed = 1 })
core.next_prompt(bstage, 0)
core.answer(bstage, core.current(bstage).combo, core.AWAY_MS - 1)
eq("just under the threshold still counts toward the average", 0,
   core.summary(bstage).away)

-- --- splits ----------------------------------------------------------------
-- A stage total says you were slow; a split says WHICH KIND of thing you were
-- slow at. Categories match on description so they survive a remapping.
eq("workspace bindings categorise",  "Workspaces",
   core.category_of({ description = "Switch to workspace 3" }))
eq("window bindings categorise",     "Windows",
   core.category_of({ description = "Close window" }))
eq("clipboard bindings categorise",  "Clipboard",
   core.category_of({ description = "Universal cut" }))
eq("media bindings categorise",      "Media",
   core.category_of({ description = "Volume up precise" }))
eq("menus categorise as System",     "System",
   core.category_of({ description = "System menu" }))
-- Everything unmatched launches something, so Apps is the catch-all.
eq("unknown bindings fall through to Apps", "Apps",
   core.category_of({ description = "Some Third Party Thing" }))
eq("a nil entry does not error",     "Apps", core.category_of(nil))
-- Specific must beat general: "Move window to workspace 3" mentions both.
eq("workspace beats window when both match", "Workspaces",
   core.category_of({ description = "Move window to workspace 3" }))

local spstage = { results = {
  { outcome = "correct", description = "Close window",          reaction_ms = 1000 },
  { outcome = "correct", description = "Full screen",           reaction_ms = 3000 },
  { outcome = "off",     description = "Universal cut",         reaction_ms = 500 },
  { outcome = "correct", description = "Switch to workspace 1", reaction_ms = 500 },
  -- An away answer must not distort a split, same as it must not distort the average.
  { outcome = "correct", description = "Switch to workspace 2", reaction_ms = 99000 },
} }
local sp = core.splits(spstage)
local byname = {}
for _, x in ipairs(sp) do byname[x.name] = x end
eq("splits group by category", 2000.0, byname["Windows"].average_ms)
eq("splits count what was asked", 2, byname["Windows"].asked)
eq("splits count offs", 1, byname["Clipboard"].offs)
eq("an off contributes no time", nil, byname["Clipboard"].average_ms)
eq("away answers are excluded from splits", 500.0, byname["Workspaces"].average_ms)
eq("but away answers still count as asked", 2, byname["Workspaces"].asked)
-- Slowest first: the point of the screen is showing where the time went.
truthy("splits are ordered slowest first",
   (sp[1].average_ms or 0) >= (sp[2].average_ms or 0))

-- --- the quattro HUD -------------------------------------------------------
-- Four driven wheels, four modifiers. Both theme and function: holding the
-- wrong modifier set is the most common way to miss a note.
local w_none = core.wheels({})
eq("the HUD is two rows", 2, #w_none)
truthy("an unheld wheel is empty", w_none[1]:find("( )", 1, true) ~= nil)
truthy("no label shows when nothing is held", w_none[1]:find("SUPER") == nil)

local w_ss = core.wheels({ SUPER = true, SHIFT = true })
truthy("a held wheel is filled", w_ss[1]:find("(#)", 1, true) ~= nil)
truthy("a held wheel is labeled", w_ss[1]:find("SUPER") ~= nil)
truthy("SHIFT sits on the second row", w_ss[2]:find("SHIFT") ~= nil)
truthy("CTRL stays empty when unheld", w_ss[1]:find("CTRL") == nil)

-- Row widths must be identical or the layout jitters as modifiers change.
eq("rows are the same width regardless of state", #w_none[1], #w_ss[1])
eq("both rows are the same width", #w_ss[1], #w_ss[2])

local all = { SUPER = true, CTRL = true, ALT = true, SHIFT = true }
eq("all four held is full quattro", true, core.full_quattro(all))
eq("three held is not full quattro", false,
   core.full_quattro({ SUPER = true, CTRL = true, ALT = true }))
eq("nothing held is not full quattro", false, core.full_quattro({}))
eq("nil is handled", false, core.full_quattro(nil))

-- --- history ---------------------------------------------------------------
-- Without persistence a run leaves no trace, which makes ghost laps, Blind
-- Spots and The Cabinet impossible to build.
local hstage = core.new_stage(bank, { length = 2, seed = 11, course = "daily-driver" })
core.next_prompt(hstage, 0)
core.answer(hstage, core.current(hstage).combo, 180)
core.next_prompt(hstage, 500)
core.answer(hstage, "SUPER + NOPE", 900, "Close window")
local rec = core.history_record(hstage, { stamp = "2026-08-24T18:00:00" })
truthy("history record is a JSON object", rec:match("^{") ~= nil and rec:match("}$") ~= nil)
truthy("history records the course", rec:find('"course":"daily%-driver"') ~= nil)
truthy("history records per-answer detail", rec:find('"answers":%[') ~= nil)
truthy("history records the off outcome", rec:find('"outcome":"off"') ~= nil)
truthy("history records reaction times", rec:find('"reaction_ms":180') ~= nil)
-- Without these a record reads "prompts: 7" with no way to know 6 were asked.
truthy("history records the original prompt count", rec:find('"base_prompts":') ~= nil)
truthy("history records requeues", rec:find('"requeues":') ~= nil)
-- Descriptions contain quotes and backslashes; unescaped they corrupt the file.
eq("json escaping handles quotes", 'a\\"b', core.json_escape('a"b'))
eq("json escaping handles backslashes", 'a\\\\b', core.json_escape('a\\b'))

-- REGRESSION: retiring mid-stage used to discard the run entirely. A partial
-- stage still carries the signal spaced repetition and Blind Spots need.
local partial = core.new_stage(bank, { length = 5, seed = 2 })
core.next_prompt(partial, 0)
core.answer(partial, core.current(partial).combo, 250)
local prec = core.history_record(partial, { stamp = "x" })
eq("REGRESSION: an unfinished stage is marked incomplete", true,
   prec:find('"completed":false') ~= nil)
truthy("REGRESSION: an unfinished stage still records its answers",
   prec:find('"answers":%[{') ~= nil)
truthy("an unfinished stage records what was answered", partial.finished == false)

-- Assisted stages are marked so they cannot set a personal best.
local astage = core.new_stage(bank, { length = 2, seed = 5 })
eq("a fresh stage is not assisted", false, astage.assisted)

-- --- summary ---------------------------------------------------------------
local s = core.summary(stage)
eq("summary counts answers", 2, s.answered)
eq("summary counts correct", 1, s.correct)
eq("summary counts offs", 1, s.offs)
eq("a stage with an off is not clean", false, s.clean)

-- Answering past the end of a stage must not error.
local short = core.new_stage(inv, { length = 1, seed = 3 })
core.next_prompt(short, 0)
core.answer(short, core.current(short).combo, 100)
core.next_prompt(short, 200)
eq("stage finishes after its last prompt", true, short.finished)
eq("answering a finished stage is safe", "no-prompt", core.answer(short, "x", 300).outcome)

-- --- spaced repetition: grading from reaction time -------------------------
-- The bridge between the racing game and the scheduler. Anki must ASK how hard
-- a card was; Omashift measures it, so grading must follow reaction time.
eq("a wrong answer grades AGAIN", core.GRADE.AGAIN,
   core.grade_for({ outcome = "off" }))
eq("a fast answer grades EASY", core.GRADE.EASY,
   core.grade_for({ outcome = "correct", tier = "zero-latency" }))
eq("an on-rails answer grades EASY", core.GRADE.EASY,
   core.grade_for({ outcome = "correct", tier = "on-rails" }))
eq("a clean-but-not-fast answer grades GOOD", core.GRADE.GOOD,
   core.grade_for({ outcome = "correct", tier = "clean" }))
eq("a slow answer grades HARD", core.GRADE.HARD,
   core.grade_for({ outcome = "correct", tier = "slow" }))
-- Assistance must cost something, or the co-driver becomes a free answer key.
eq("a co-driver-assisted answer grades HARD", core.GRADE.HARD,
   core.grade_for({ outcome = "correct", tier = "zero-latency", assisted = true }))

-- --- SM-2 interval progression ---------------------------------------------
local item = core.new_item("SUPER + W")
local day = 0
local intervals = {}
for _ = 1, 5 do
  item = core.schedule(item, core.GRADE.GOOD, day)
  intervals[#intervals + 1] = item.interval
  day = item.due_day
end
eq("graduating interval is 1 day", 1, intervals[2])
eq("second review uses Anki's 6-day interval", 6, intervals[3])
truthy("intervals expand thereafter", intervals[4] > intervals[3])
truthy("expansion accelerates", (intervals[5] - intervals[4]) > (intervals[4] - intervals[3]))

-- --- lapses -----------------------------------------------------------------
-- The core promise: a binding you keep fumbling comes back sooner and stays
-- frequent. Without this the scheduler is just a shuffle with extra steps.
local mature = core.new_item("SUPER + G")
for _ = 1, 4 do mature = core.schedule(mature, core.GRADE.GOOD, mature.due_day) end
local before_ease, before_interval = mature.ease, mature.interval
truthy("a mature item has a long interval", before_interval > 6)
mature = core.schedule(mature, core.GRADE.AGAIN, mature.due_day)
eq("REGRESSION: a lapse returns the item to learning steps", 0, mature.interval)
eq("a lapse is counted", 1, mature.lapses)
truthy("a lapse shrinks ease", mature.ease < before_ease)
truthy("a lapsed item is due immediately", mature.due_day <= mature.due_day)

-- Ease must not fall without bound, or a hard item becomes permanently stuck.
local punished = core.new_item("SUPER + X")
for _ = 1, 20 do punished = core.schedule(punished, core.GRADE.AGAIN, 0) end
truthy("ease floors at EASE_FLOOR", punished.ease >= core.EASE_FLOOR)
eq("ease floors exactly", core.EASE_FLOOR, punished.ease)

-- EASY must outpace GOOD, or the grading distinction buys nothing.
local easy, good = core.new_item("a"), core.new_item("b")
for _ = 1, 4 do
  easy = core.schedule(easy, core.GRADE.EASY, easy.due_day)
  good = core.schedule(good, core.GRADE.GOOD, good.due_day)
end
truthy("EASY grows intervals faster than GOOD", easy.interval > good.interval)

-- --- queue selection --------------------------------------------------------
local inv2 = {
  { combo = "A", description = "a", modmask = 64 },
  { combo = "B", description = "b", modmask = 64 },
  { combo = "C", description = "c", modmask = 8  },
  { combo = "D", description = "d", modmask = 8  },
}
local sched = {
  A = { combo = "A", ease = 2.5, interval = 5, due_day = 1,  reps = 2, lapses = 0, step = 1 }, -- overdue
  B = { combo = "B", ease = 2.5, interval = 5, due_day = 99, reps = 2, lapses = 0, step = 1 }, -- not due
  C = { combo = "C", ease = 2.5, interval = 5, due_day = 9,  reps = 2, lapses = 0, step = 1 }, -- due today
}
local due_order = core.select_due(inv2, sched, 9, 4)
eq("most overdue item comes first", "A", due_order[1].combo)
eq("due-today item comes next", "C", due_order[2].combo)
-- An item never shown has no interval, which is exactly the Blind Spots set.
eq("never-seen items outrank not-yet-due ones", "D", due_order[3].combo)
eq("not-yet-due items are filler", "B", due_order[4].combo)
eq("selection respects the requested count", 2, #core.select_due(inv2, sched, 9, 2))
local again = core.select_due(inv2, sched, 9, 4)
truthy("selection is deterministic", due_order[1].combo == again[1].combo
       and due_order[2].combo == again[2].combo and due_order[3].combo == again[3].combo)

-- --- randomness quality -----------------------------------------------------
-- Both of these shipped biased, and both looked fine until measured. An LCG's
-- LOW bits have a very short period, so `rng % n`, the obvious spelling, is
-- the trap. These assertions exist because the naive version passes every
-- functional test while quietly ruining the game.
local rinv = {}
for i = 1, 8 do rinv[i] = { combo = "K" .. i, modmask = (i % 4) * 8, description = "D" .. i } end

-- The shuffle decides which bindings a stage contains. Biased, it drills some
-- several times as often as others: the first entry led 466 times in 2000 and
-- the last 65, against an ideal of 250.
local lead = {}
for seed = 1, 2000 do
  local sh = core.shuffled(rinv, seed)
  lead[sh[1].description] = (lead[sh[1].description] or 0) + 1
end
local worst_lead = 0
for i = 1, 8 do
  local dev = math.abs((lead["D" .. i] or 0) - 250)
  if dev > worst_lead then worst_lead = dev end
end
truthy(("no entry dominates first place (worst deviation %d, ideal <100)"):format(worst_lead),
  worst_lead < 100)

-- Every entry must reach every position, not merely appear somewhere.
local reaches = 0
for pos = 1, 8 do
  if core.shuffled(rinv, pos * 37)[pos] then reaches = reaches + 1 end
end
eq("a shuffle fills every position", 8, reaches)

-- The requeue gap. A constant made a miss return as exactly the second prompt
-- after it, so you braced rather than recalled; the first fix used low bits and
-- produced 4,5,2,3 repeating forever, which is just a longer tell.
local gap_counts, series = {}, {}
local gstage = core.new_stage(rinv, { length = 8, seed = 5 })
-- A DISTINCT NOTE EACH TIME. Requeue is capped at one return per note now, so
-- sampling the gap distribution by re-queuing one description two hundred times
-- measures the cap instead of the gap. The cap has its own test below.
for i = 1, 200 do
  core.next_prompt(gstage, i)
  local at = core.requeue(gstage,
    { combo = "R" .. i, description = "retry " .. i, modmask = 64 })
  local gap = at - gstage.index
  gap_counts[gap] = (gap_counts[gap] or 0) + 1
  series[#series + 1] = gap
end
for gap = core.REQUEUE_GAP.min, core.REQUEUE_GAP.max do
  truthy(("gap %d occurs"):format(gap), (gap_counts[gap] or 0) > 0)
end
eq("no gap below the minimum", nil, gap_counts[core.REQUEUE_GAP.min - 1])
eq("no gap above the maximum", nil, gap_counts[core.REQUEUE_GAP.max + 1])
-- --- a note comes back ONCE ------------------------------------------------
--
-- Uncapped, this is a loop with no exit. A real Endurance run asked ten notes
-- and delivered twenty-three, because a binding the player could not physically
-- press came back every time it was missed and missing it was the only
-- available outcome. The stage could not end.
do
  local st = core.new_stage(rinv, { length = 6, seed = 11 })
  core.next_prompt(st, 1)
  local entry = { combo = "Z", description = "unpressable", modmask = 0 }
  local first = core.requeue(st, entry)
  truthy("a missed note comes back", first ~= nil)
  -- Twice, because missing something, seeing it again and missing it again is
  -- an ordinary way to learn a chord. A third time is the schedule's job.
  truthy("and a second time", core.requeue(st, entry) ~= nil)
  eq("but not a third", nil, core.requeue(st, entry))
  eq("and again is still nil", nil, core.requeue(st, entry))
  eq("the limit is stated, not implied", 2, core.REQUEUE_LIMIT)

  -- Identity is the DESCRIPTION, the same as everywhere else in this codebase:
  -- one action reachable by two chords is one note, and it must not get a
  -- second return by coming back under its other name.
  eq("an alias of the same action does not get another",
     nil, core.requeue(st, { combo = "ZZ", description = "unpressable", modmask = 0 }))

  -- THE BOUND. Whatever a player does, a stage of N notes cannot deliver more
  -- than N * (1 + limit) prompts, so it always ends.
  local n = 6
  local st3 = core.new_stage(rinv, { length = n, seed = 7 })
  core.next_prompt(st3, 1)
  for _ = 1, 5 do
    for i = 1, n do
      core.requeue(st3, { combo = "M" .. i, description = "m" .. i, modmask = 0 })
    end
  end
  truthy("a stage can at most triple", #st3.prompts <= n * (1 + core.REQUEUE_LIMIT))

  -- A DIFFERENT note is unaffected. The cap is per note, not per stage: a
  -- player who misses four different things should see all four again.
  truthy("a different note still comes back",
     core.requeue(st, { combo = "Y", description = "something else", modmask = 0 }) ~= nil)

  -- The bound that matters: a stage can at most double.
  local st2 = core.new_stage(rinv, { length = 5, seed = 3 })
  core.next_prompt(st2, 1)
  for i = 1, 40 do
    core.requeue(st2, { combo = "K" .. i, description = "note " .. i, modmask = 0 })
  end
  truthy("a stage cannot grow without bound", #st2.prompts <= 5 + 40)
end

-- --- the order courses are offered in ---------------------------------------
--
-- A decision, not an accident. It was alphabetical, which put Service Park
-- fifth of nine purely because of how it is spelled. Cycling with C should run
-- from the things you do constantly out to the ones you barely touch.
do
  local names = core.course_names()
  eq("the tour starts where a new player should", "daily-driver", names[1])
  eq("and ends with the catch-all", "service-park", names[#names])
  eq("which is named rather than implied", "service-park", core.COURSE_TAIL)

  -- Every shipped course is offered, exactly once. A name dropped from the
  -- order would silently vanish from the menu.
  local count, seen = 0, {}
  for _ in pairs(core.COURSES) do count = count + 1 end
  eq("every course is offered", count, #names)
  for _, n in ipairs(names) do
    eq(("%s is offered once"):format(n), nil, seen[n])
    seen[n] = true
    truthy(("%s is a real course"):format(n), core.COURSES[n] ~= nil)
  end

  -- The property that says this is deliberate. Alphabetical order is exactly
  -- what it used to be, so a regression would restore it.
  local alphabetical = {}
  for _, n in ipairs(names) do alphabetical[#alphabetical + 1] = n end
  table.sort(alphabetical)
  truthy("the order is not merely alphabetical",
    table.concat(names, ",") ~= table.concat(alphabetical, ","))

  -- A course somebody writes in their own courses.lua reaches the menu, and it
  -- goes in FRONT of the catch-all: Service Park is where things end up when
  -- they belong nowhere, so anything that arrives later belongs before it.
  core.COURSES["zzz-mine"] = { label = "Mine", patterns = { "^Nothing$" } }
  local withMine = core.course_names()
  core.COURSES["zzz-mine"] = nil
  eq("a course of your own is offered", "zzz-mine", withMine[#withMine - 1])
  eq("and still behind nothing but the catch-all", "service-park", withMine[#withMine])
end

-- --- giving up on a note for good ------------------------------------------
--
-- A skip gets you past a note today. Without this the note is back tomorrow,
-- and on a keyboard missing a key that is a loop with no end: a trainer that
-- keeps asking a question you have twice said you cannot answer is not training
-- anything.
do
  local function skip_record(stamp, answers)
    local parts = {}
    for _, a in ipairs(answers) do
      parts[#parts + 1] = ('{"combo":"%s","description":"%s","outcome":"%s","reaction_ms":%d}')
        :format(a[1], a[2], a[3], a[4] or 0)
    end
    return ('{"stamp":"%s","course":"x","prompts":1,"correct":0,"offs":0,"points":0,"average_ms":0,"assisted":false,"completed":true,"clean":false,"answers":[%s]}')
      :format(stamp, table.concat(parts, ","))
  end

  local once = skip_record("2026-08-27T09:00:00", {
    { "A", "OCR", "skipped" }, { "B", "Terminal", "correct", 900 } })
  local twice = once .. "\n"
    .. skip_record("2026-08-27T10:00:00", { { "A", "OCR", "skipped" } })

  eq("one skip does not retire anything", nil, core.retired_actions(once)["OCR"])
  eq("two does", 2, core.retired_actions(twice)["OCR"])
  eq("the threshold is stated", 2, core.RETIRE_AFTER_SKIPS)
  eq("and the count is available to the screen", 1, core.skip_count(once, "OCR"))

  local inv = { { combo = "A", description = "OCR" }, { combo = "B", description = "Terminal" } }
  eq("nothing is dropped before the threshold", 2, #core.without_retired(inv, once))
  eq("and the retired action is dropped after", 1, #core.without_retired(inv, twice))
  eq("but only that one", "Terminal", core.without_retired(inv, twice)[1].description)

  -- A SKIP IS NOT A MISS. This is the whole reason it is a separate outcome: if
  -- Blind Spots read it as evidence, the game would drill the one binding it
  -- can never teach, and it would drill it harder every time you gave up.
  eq("a skip never becomes a blind spot", nil, core.previously_missed(twice)["OCR"])
  local spots = core.blind_spots(twice)
  local named = false
  for _, r in ipairs(spots) do
    if r.description == "OCR" then named = true end
  end
  eq("not even after two of them", false, named)

  -- No history at all must not retire everything, which is what a careless
  -- "count is not less than the limit" would do with nil counts.
  eq("an empty history retires nothing", 2, #core.without_retired(inv, ""))
end

-- PERIODICITY, not repetition. The low-bit version produced 4,5,2,3 over and
-- over, a dead giveaway to a player, but it never repeats a value twice in a
-- row, so a "longest identical run" check passes it happily. That check was
-- written first and had to be thrown away.
local function period_of(t)
  for p = 1, 12 do
    local periodic = true
    for i = 1, #t - p do
      if t[i] ~= t[i + p] then periodic = false; break end
    end
    if periodic then return p end
  end
  return nil
end
eq("gaps are not periodic", nil, period_of(series))

-- Reproducible from the seed, or a recorded run cannot be replayed and the
-- ghost stops being comparable.
local function gap_series(seed)
  local st = core.new_stage(rinv, { length = 8, seed = seed })
  local out = {}
  for i = 1, 6 do
    core.next_prompt(st, i)
    -- Distinct notes, for the same reason as the distribution sample above: the
    -- cap allows one return per note, and this is measuring the RNG.
    out[#out + 1] = core.requeue(
      st, { combo = "R" .. i, description = "r" .. i, modmask = 64 }) - st.index
  end
  return table.concat(out, ",")
end
eq("the same seed replays the same gaps", gap_series(11), gap_series(11))
truthy("different seeds differ", gap_series(11) ~= gap_series(12))

-- --- within-stage requeue ---------------------------------------------------
-- The second timescale: a fresh miss returns while it is still warm, rather
-- than waiting a day. SM-2 alone cannot express this.
local rq = core.new_stage(inv, { length = 6, seed = 4 })
core.next_prompt(rq, 0)
local before_len = #rq.prompts
local at = core.requeue(rq, { combo = "RETRY", description = "retry", modmask = 64 }, 2)
eq("requeue lengthens the stage", before_len + 1, #rq.prompts)
eq("requeue lands ahead of the current position", rq.index + 2, at)
eq("the requeued entry is where it was placed", "RETRY", rq.prompts[at].combo)
-- Requeuing near the end must not run off the array.
local tail = core.new_stage(inv, { length = 2, seed = 5 })
tail.index = 2
core.requeue(tail, { combo = "TAIL", description = "t", modmask = 8 }, 99)
eq("requeue past the end appends safely", "TAIL", tail.prompts[#tail.prompts].combo)

-- --- persistence ------------------------------------------------------------
-- Hyprland's Lua sandbox has no JSON parser, so schedules persist as code.
local out = core.serialize_schedule(sched)
local chunk = load(out)
truthy("serialized schedule is valid Lua", chunk ~= nil)
local restored = chunk()
eq("round-trip preserves interval", 5, restored.A.interval)
eq("round-trip preserves due day", 1, restored.A.due_day)
truthy("round-trip preserves ease", math.abs(restored.A.ease - 2.5) < 0.001)
-- Deterministic output keeps diffs readable and makes the file reviewable.
eq("serialization is deterministic", out, core.serialize_schedule(sched))

print()
if failed == 0 then
  print(("\27[32mcore: %d passed\27[0m"):format(run))
  os.exit(0)
end
print(("\27[31mcore: %d of %d FAILED\27[0m"):format(failed, run))
os.exit(1)

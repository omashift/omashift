-- Tests for lib/trophies.lua: the Cabinet's earn rules.
--
-- The rules matter more than they look. A trophy that re-fires is worse than no
-- trophy: it turns a permanent record into a popup, which is exactly the thing
-- the four-class design exists to prevent. Most of what follows is checking that
-- something is earned ONCE.

package.path = (arg[0]:match("(.*/)") or "./") .. "../lib/?.lua;" .. package.path
local T = require("trophies")
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

print("trophies:")

-- A stage that is clean, unaided and perfect unless told otherwise.
local function ctx(over)
  local c = {
    course = "daily-driver", completed = true, assisted = false, day = "2026-08-25",
    summary = { prompts = 6, correct = 6, offs = 0, clean = true, requeues = 0, average_ms = 1500 },
    results = {},
  }
  for i = 1, 6 do c.results[i] = { outcome = "correct", tier = "clean", description = "D" .. i } end
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

local function won_ids(list)
  local out = {}
  for _, w in ipairs(list) do out[w.id] = w.tier or true end
  return out
end

-- --- earning once ----------------------------------------------------------
local cab = T.new_cabinet()
local first = won_ids(T.record(cab, ctx()))
truthy("a clean unaided run wins Direct Drive", first["direct-drive"])
truthy("...and Getting Real",                   first["getting-real"])
truthy("...and Conversion Rate",                first["conversion-rate"])
truthy("...and Omakase",                        first["omakase"])
truthy("...and Open Sesame",                    first["open-sesame"])

-- The whole point of a cabinet over a popup: it does not fire twice.
eq("an identical second run wins nothing", 0, #(T.record(cab, ctx())))

-- --- mastery is scoped per course ------------------------------------------
local other = won_ids(T.record(cab, ctx({ course = "the-commute" })))
truthy("mastery can be won again on another course", other["direct-drive"])
truthy("Open Sesame is per course too",             other["open-sesame"])
-- ...but a milestone that is not per-course stays won.
eq("Omakase does not re-fire on another course", nil, other["omakase"])

-- --- repeatables tier rather than spam -------------------------------------
-- Zero Latency would fire dozens of times a session as a plain badge. Tiering it
-- 1/10/50 keeps the phrase and makes it a progression.
local rc = T.new_cabinet()
local function fast_stage(n)
  local rs = {}
  for i = 1, n do rs[i] = { outcome = "correct", tier = "zero-latency", description = "Z" .. i } end
  return ctx({ results = rs, summary = { prompts = n, correct = n, offs = 0, clean = true,
                                         requeues = 0, average_ms = 500 } })
end
eq("the first fast answer is bronze", "bronze", won_ids(T.record(rc, fast_stage(1)))["zero-latency"])
eq("count accumulates across stages", 1, rc.counts["zero-latency"])
-- Eight more takes it to 9, still short of silver, so nothing new is awarded.
eq("progress below the next tier awards nothing", nil, won_ids(T.record(rc, fast_stage(8)))["zero-latency"])
eq("...but the count still rises", 9, rc.counts["zero-latency"])
eq("crossing ten is silver", "silver", won_ids(T.record(rc, fast_stage(1)))["zero-latency"])
eq("crossing fifty is gold", "gold", won_ids(T.record(rc, fast_stage(40)))["zero-latency"])
eq("gold is the last tier", nil, won_ids(T.record(rc, fast_stage(100)))["zero-latency"])
eq("tier_for_count is nil below bronze", nil, T.tier_for_count(0, T.TIERS))

-- --- the conditions that are easy to get wrong -----------------------------
-- Cache Hit is the interesting one: recalling something you HAD missed.
local ch = T.new_cabinet()
local hit = won_ids(T.record(ch, ctx({ previously_missed = { D2 = true, D5 = true } })))
truthy("recalling a previously missed binding is a Cache Hit", hit["cache-hit"])
eq("both recalls counted", 2, ch.counts["cache-hit"])
eq("no prior misses means no Cache Hit", nil,
   won_ids(T.record(T.new_cabinet(), ctx()))["cache-hit"])

-- Fast Off The Blocks is about the START, not the stage.
local slowstart = ctx()
slowstart.results[2] = { outcome = "off", tier = "slow", description = "D2" }
eq("a miss in the first three blocks the start", nil,
   won_ids(T.record(T.new_cabinet(), slowstart))["fast-off-the-blocks"])

-- Presence is flow: six consecutive answers with no hesitation.
local five = ctx()
five.results = {}
for i = 1, 5 do five.results[i] = { outcome = "correct", tier = "clean", description = "D" .. i } end
eq("five in a row is not yet Presence", nil, won_ids(T.record(T.new_cabinet(), five))["presence"])
local broken = ctx()
broken.results[4] = { outcome = "correct", tier = "slow", description = "D4" }
eq("a slow answer breaks flow", nil, won_ids(T.record(T.new_cabinet(), broken))["presence"])

-- Rework needs something to beat. Without a previous time it cannot be earned,
-- which is why the first run on a course never wins it.
eq("no previous average means no Rework", nil,
   won_ids(T.record(T.new_cabinet(), ctx()))["rework"])
truthy("beating your previous average is Rework",
   won_ids(T.record(T.new_cabinet(), ctx({ previous_course_average = 2000 })))["rework"])
eq("a slower run is not Rework", nil,
   won_ids(T.record(T.new_cabinet(), ctx({ previous_course_average = 1000 })))["rework"])

-- Omakase is "the menu, exactly as designed", so a generated course cannot win
-- it and a re-asked note disqualifies the run.
eq("Blind Spots cannot win Omakase", nil,
   won_ids(T.record(T.new_cabinet(), ctx({ course = "blind-spots" })))["omakase"])
truthy("Blind Spots wins Built To Order",
   won_ids(T.record(T.new_cabinet(), ctx({ course = "blind-spots" })))["built-to-order"])
eq("a curated course does not win Built To Order", nil,
   won_ids(T.record(T.new_cabinet(), ctx()))["built-to-order"])
local requeued = ctx()
requeued.summary.requeues = 1
eq("a re-asked note disqualifies Omakase", nil,
   won_ids(T.record(T.new_cabinet(), requeued))["omakase"])
eq("the co-driver disqualifies Omakase", nil,
   won_ids(T.record(T.new_cabinet(), ctx({ assisted = true })))["omakase"])
-- ...but a called stage still trains, so the softer mastery is still winnable.
truthy("a called stage still wins Conversion Rate",
   won_ids(T.record(T.new_cabinet(), ctx({ assisted = true })))["conversion-rate"])
eq("a called stage does not win Direct Drive", nil,
   won_ids(T.record(T.new_cabinet(), ctx({ assisted = true })))["direct-drive"])

-- The endgame pair, which waited on the Endurance course and now ships with it.
truthy("Sharp Knives is in the catalog", T.by_id("sharp-knives") ~= nil)
eq("Endurance trophies are no longer locked", nil, T.by_id("sharp-knives").locked)
eq("an ordinary course does not win Sharp Knives", nil,
   won_ids(T.record(T.new_cabinet(), ctx()))["sharp-knives"])
truthy("finishing Endurance wins Sharp Knives",
   won_ids(T.record(T.new_cabinet(), ctx({ course = "endurance" })))["sharp-knives"])
truthy("a clean Endurance run wins Class Win",
   won_ids(T.record(T.new_cabinet(), ctx({ course = "endurance" })))["class-win"])
local messy = ctx({ course = "endurance" })
messy.summary.clean = false
eq("a scrappy Endurance run wins Sharp Knives but not Class Win", nil,
   won_ids(T.record(T.new_cabinet(), messy))["class-win"])
-- The `locked` mechanism itself still has to work for whatever comes next.
eq("a locked trophy would be skipped in the listing", nil, T.by_id("class-win").locked)

-- --- day streaks -----------------------------------------------------------
eq("an ISO date converts to a day number", true, T.day_number("2026-08-25") ~= nil)
eq("a malformed date converts to nil", nil, T.day_number("not-a-date"))
eq("consecutive days are one apart", 1,
   T.day_number("2026-08-25") - T.day_number("2026-08-24"))
-- Month and year boundaries are where naive date maths breaks.
eq("a month boundary is one day", 1, T.day_number("2026-09-01") - T.day_number("2026-08-31"))
eq("a year boundary is one day",  1, T.day_number("2027-01-01") - T.day_number("2026-12-31"))

eq("no days is no streak", 0, T.day_streak({}, "2026-08-25"))
eq("three consecutive days is three", 3,
   T.day_streak({ "2026-08-23", "2026-08-24", "2026-08-25" }, "2026-08-25"))
eq("a gap resets the streak", 2,
   T.day_streak({ "2026-08-20", "2026-08-24", "2026-08-25" }, "2026-08-25"))
-- Not playing today means the run has ended, whatever came before it.
eq("a streak must include today", 0,
   T.day_streak({ "2026-08-23", "2026-08-24" }, "2026-08-26"))

local sc = T.new_cabinet()
T.record(sc, ctx({ day = "2026-08-23" }))
T.record(sc, ctx({ day = "2026-08-24" }))
local third = won_ids(T.record(sc, ctx({ day = "2026-08-25" })))
eq("three days running is a bronze streak", "bronze", third["compound-interest"])
-- Playing twice in one day must not advance a DAY streak.
eq("a second run the same day earns no streak", nil,
   won_ids(T.record(sc, ctx({ day = "2026-08-25" })))["compound-interest"])
eq("the day is recorded once", 3, #sc.days)

-- --- the cabinet file ------------------------------------------------------
-- Plain readable JSON, because a trophy case should never be opaque.
local text = core.serialize_cabinet(sc)
truthy("the file names its counts", text:find('"counts"', 1, true) ~= nil)
truthy("the file names its days",   text:find('"days"', 1, true) ~= nil)
local back = core.parse_cabinet(text)
eq("counts survive a round trip", sc.counts["presence"], back.counts["presence"])
eq("days survive a round trip", #sc.days, #back.days)
eq("earned keys survive a round trip", sc.earned["omakase"], back.earned["omakase"])
-- Deterministic output, so the file diffs cleanly when a human reads it.
eq("serialization is deterministic", core.serialize_cabinet(sc), core.serialize_cabinet(sc))
-- A missing or corrupt file must degrade to an empty cabinet, not an error.
local empty = core.parse_cabinet("")
eq("no file yields an empty cabinet", 0, #empty.days)
eq("...with no counts", nil, empty.counts["presence"])
eq("garbage yields an empty cabinet", 0, #core.parse_cabinet("{ not json").days)

-- A round trip must let earning resume exactly where it left off.
local resumed = core.parse_cabinet(core.serialize_cabinet(rc))
eq("counts resume from the file", 150, resumed.counts["zero-latency"])
eq("a reloaded cabinet awards nothing already won", nil,
   won_ids(T.record(resumed, fast_stage(1)))["zero-latency"])

-- --- Oligarchy, the secret one ----------------------------------------------
--
-- The endgame trophy, and the only one that is not on the roadmap. Two things
-- have to hold and they pull against each other: it must be invisible until it
-- is won, and it must actually be winnable. A hidden trophy whose unlock
-- condition is quietly unsatisfiable is indistinguishable from one that does
-- not exist, and nobody would ever report the bug.

local COURSES = core.course_names()

-- A cabinet with everything except Oligarchy at its ceiling, built FROM the
-- catalog rather than from a hand-written list. A trophy added next month is
-- automatically part of the requirement, which is the whole point of the rule,
-- and a hand-written list would have silently stopped covering it.
local function topped_out()
  local c = T.new_cabinet()
  local gold = T.TIERS[#T.TIERS].name
  local gold_streak = T.STREAK_TIERS[#T.STREAK_TIERS].name
  for _, t in ipairs(T.CATALOG) do
    if t.class ~= "secret" then
      if t.class == "repeatable" then
        c.counts[T.key(t)] = T.TIERS[#T.TIERS].at
        c.earned[T.key(t) .. "@" .. gold] = "2026-08-25"
      elseif t.class == "streak" then
        c.counts[T.key(t)] = T.STREAK_TIERS[#T.STREAK_TIERS].at
        c.earned[T.key(t) .. "@" .. gold_streak] = "2026-08-25"
      elseif t.class == "mastery" or t.per_course then
        for _, course in ipairs(COURSES) do c.earned[T.key(t, course)] = "2026-08-25" end
      else
        c.earned[T.key(t)] = "2026-08-25"
      end
    end
  end
  return c
end

truthy("a full case is topped out", T.is_topped_out(topped_out(), COURSES))
eq("an empty one is not", false, T.is_topped_out(T.new_cabinet(), COURSES))
-- Vacuous truth is the way a completion check hands out the endgame for free:
-- "earned on every course" is trivially satisfied by no courses at all.
eq("and no courses is not an answer", false, T.is_topped_out(topped_out(), {}))
eq("nor is a missing cabinet", false, T.is_topped_out(nil, COURSES))

-- Knock out one requirement at a time. Each of these is a way the check could
-- be too generous, and every one of them would look exactly like working.
do
  local holes = 0
  for _, t in ipairs(T.CATALOG) do
    if t.class ~= "secret" then
      local c = topped_out()
      if t.class == "repeatable" then
        c.earned[T.key(t) .. "@" .. T.TIERS[#T.TIERS].name] = nil
      elseif t.class == "streak" then
        c.earned[T.key(t) .. "@" .. T.STREAK_TIERS[#T.STREAK_TIERS].name] = nil
      elseif t.class == "mastery" or t.per_course then
        -- ONE course short, not all of them. Grinding the easy course is not
        -- mastery, and it must not be the endgame either.
        c.earned[T.key(t, COURSES[#COURSES])] = nil
      else
        c.earned[T.key(t)] = nil
      end
      if T.is_topped_out(c, COURSES) then holes = holes + 1 end
    end
  end
  eq("every single trophy is required", 0, holes)
end

-- Silver is not gold. The obvious wrong implementation checks that a tier was
-- reached at all.
do
  local c = topped_out()
  for _, t in ipairs(T.CATALOG) do
    if t.class == "repeatable" then
      c.earned[T.key(t) .. "@gold"] = nil
      c.earned[T.key(t) .. "@silver"] = "2026-08-25"
    end
  end
  eq("silver on the repeatables is not enough", false, T.is_topped_out(c, COURSES))
end

-- A trophy nobody can win yet must not make this one unwinnable for everyone.
do
  local c = topped_out()
  T.CATALOG[#T.CATALOG + 1] = {
    id = "not-yet-possible", phrase = "Not Yet", class = "milestone",
    locked = "waiting on something that does not exist", note = "-",
    earned = function() return false end,
  }
  local still = T.is_topped_out(c, COURSES)
  T.CATALOG[#T.CATALOG] = nil
  truthy("a locked trophy does not block it", still)
end

-- Awarded through record(), once, on the run that completes the case.
do
  local c = topped_out()
  local won = T.record(c, ctx({ courses = COURSES }))
  local ids = won_ids(won)
  truthy("finishing the case unlocks Oligarchy", ids["oligarchy"] ~= nil)
  eq("and it is marked secret", true, won[#won].secret)

  local again = won_ids(T.record(c, ctx({ courses = COURSES })))
  eq("and it is never won twice", nil, again["oligarchy"])
end

-- Without the course list it can never unlock, and the engine is the only
-- caller that supplies it. This is the assertion that catches that wire coming
-- loose, because nothing else would: the trophy would simply never appear.
do
  local c = topped_out()
  eq("no course list means no award", nil, won_ids(T.record(c, ctx()))["oligarchy"])
end

-- An ordinary player must not trip it. Every trophy in the case is reachable,
-- so a check that was accidentally true would hand the endgame to a beginner.
do
  local c = T.new_cabinet()
  eq("a first stage does not unlock it", nil,
     won_ids(T.record(c, ctx({ courses = COURSES })))["oligarchy"])
end

print()
if failed == 0 then
  print(("\27[32mtrophies: %d passed\27[0m"):format(run))
else
  print(("\27[31mtrophies: %d of %d FAILED\27[0m"):format(failed, run))
  os.exit(1)
end

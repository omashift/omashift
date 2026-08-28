-- Tests for lib/stats.lua, the Logbook.
-- Run directly:  lua test/test-stats.lua
--
-- The screen answers one question, so most of what is worth testing is the
-- ways it could answer it WRONGLY and still look fine: counting a walk-away as
-- a failure, comparing a hard course against an easy one, or announcing a
-- trajectory from three stages.
--
-- Everything here is pure input to pure output. No compositor, no clock, no
-- files beyond one fixture read as text.

local HERE = (arg[0]:match("(.*/)") or "./")
package.path = HERE .. "../lib/?.lua;" .. package.path
local stats = require("stats")
local screens = require("screens")

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

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local t = f:read("*a"); f:close(); return t
end

local FIXTURE = read(HERE .. "fixtures/stats/history.jsonl")
assert(FIXTURE, "missing test/fixtures/stats/history.jsonl")

-- Build one history line, so a test can state the exact shape it is about
-- rather than hunting for a run in the fixture that happens to have it.
local function line(o)
  local answers = {}
  for _, a in ipairs(o.answers) do
    answers[#answers + 1] = ('{"combo":"%s","description":"%s","outcome":"%s","pressed":"%s","reaction_ms":%d}')
      :format(a.combo or "SUPER + X", a.description, a.outcome, a.combo or "SUPER + X", a.reaction_ms or 0)
  end
  return ('{"stamp":"%s","course":"%s","difficulty":"%s","prompts":%d,"correct":%d,"offs":%d,"points":0,"average_ms":%d,"assisted":%s,"completed":%s,"clean":%s,"answers":[%s]}')
    :format(o.stamp, o.course or "daily-driver", o.difficulty or "medium",
      o.prompts or #o.answers, o.correct or #o.answers, o.offs or 0, o.average_ms or 0,
      tostring(o.assisted == true), tostring(o.completed ~= false), tostring(o.clean == true),
      table.concat(answers, ","))
end

print("stats:")

-- --- nothing played --------------------------------------------------------
do
  local m = stats.model("")
  truthy("an empty history still builds a model", m ~= nil)
  eq("and says so", true, m.empty)
  eq("and names itself", "stats", m.screen)
  eq("with no trend to report", false, m.trend.enough)
  -- The screen must survive the very first launch. A nil indexed anywhere in
  -- here is a crash on the one screen a new player is most likely to open.
  local lines = screens.render(m)
  truthy("and renders without erroring", #lines > 0)
end

do
  local m = stats.model("not json at all\nneither is this\n")
  eq("garbage is the same as nothing", true, m.empty)
end

-- --- a walk-away is not a failure ------------------------------------------
--
-- THE BIGGEST WAY THIS SCREEN COULD LIE. A retired stage records the prompts it
-- PLANNED, so a stage abandoned after one answer is on disk as 1 correct out of
-- 5. Anything that divides by `prompts` reads that as 20% and drags the whole
-- trend down for a stage nobody played.
do
  local bail = line({
    stamp = "2026-06-01T09:00:00", prompts = 10, correct = 1, completed = false,
    answers = { { description = "Terminal", outcome = "correct", reaction_ms = 1000 } },
  })
  local m = stats.model(bail)
  eq("accuracy is over answers GIVEN", 100, m.last.accuracy)
  eq("and the walk-away is still visible", 10, m.last.planned)
  eq("with one answer counted", 1, m.last.answered)

  -- And it is kept out of the chart, where a single point is a cliff.
  eq("a bail is not plotted", 0, #m.series)

  local said = table.concat(m.last.notes, " | ")
  truthy("the screen says it was retired", said:find("retired", 1, true) ~= nil)
end

-- --- too little data is said out loud --------------------------------------
do
  local text = {}
  for i = 1, 3 do
    text[#text + 1] = line({
      stamp = ("2026-06-0%dT09:00:00"):format(i),
      answers = {
        { description = "Terminal", outcome = "correct", reaction_ms = 1000 },
        { description = "Browser", outcome = "correct", reaction_ms = 1200 },
        { description = "Full screen", outcome = "correct", reaction_ms = 1100 },
      },
    })
  end
  local m = stats.model(table.concat(text, "\n"))
  eq("three stages is not a trajectory", false, m.trend.enough)
  eq("and the screen names what it needs", stats.MIN_TREND_STAGES, m.trend.needed)
  -- A verdict from three stages is noise wearing a conclusion's clothes.
  eq("with no verdict attached", nil, m.trend.verdict)
end

-- --- the paired comparison controls for what was asked ---------------------
--
-- The confound that matters. A player who moves from an easy course to a hard
-- one looks slower on the headline and is faster on the bindings they share,
-- and the second one is the true answer.
do
  local text = {}
  -- Seven early stages, answered slowly. Seven and not six so that the whole
  -- of the recent window is the harder course: the comparison splits at the
  -- last WINDOW stages, and one endurance stage on the early side would have
  -- put the new binding in both windows and paired it with itself.
  for i = 1, 7 do
    text[#text + 1] = line({
      stamp = ("2026-06-0%dT09:00:00"):format(i),
      answers = {
        { description = "Terminal", outcome = "correct", reaction_ms = 3000 },
        { description = "Browser", outcome = "correct", reaction_ms = 3100 },
        { description = "Full screen", outcome = "correct", reaction_ms = 2900 },
        { description = "Close window", outcome = "correct", reaction_ms = 3050 },
      },
    })
  end
  -- Five recent stages: the SAME bindings answered faster, plus a hard new one
  -- that is slow enough to drag any naive average the wrong way.
  for i = 1, 5 do
    text[#text + 1] = line({
      stamp = ("2026-06-1%dT09:00:00"):format(i),
      course = "endurance",
      answers = {
        { description = "Terminal", outcome = "correct", reaction_ms = 1000 },
        { description = "Browser", outcome = "correct", reaction_ms = 1100 },
        { description = "Full screen", outcome = "correct", reaction_ms = 900 },
        { description = "Close window", outcome = "correct", reaction_ms = 1050 },
        { description = "Toggle waybar", outcome = "correct", reaction_ms = 20000 },
      },
    })
  end

  local m = stats.model(table.concat(text, "\n"))
  local p = m.trend.paired
  truthy("enough shared bindings to compare", p.enough)
  eq("only the shared ones are paired", 4, p.compared)
  eq("and all four improved", 4, p.improved)
  truthy("by a large margin", p.median_delta_ms <= -1500)
  -- The headline median is dragged upward by the new hard binding. The verdict
  -- must follow the paired number, not the headline.
  eq("the verdict follows the paired number", "faster", m.trend.verdict)
end

-- --- a real slowdown is reported as one ------------------------------------
--
-- The mirror of the test above, and the one that proves the screen is not just
-- printing "faster" unconditionally. A stats screen that always has good news
-- teaches the player to stop reading it.
do
  local text = {}
  for i = 1, 6 do
    text[#text + 1] = line({
      stamp = ("2026-06-0%dT09:00:00"):format(i),
      answers = {
        { description = "Terminal", outcome = "correct", reaction_ms = 900 },
        { description = "Browser", outcome = "correct", reaction_ms = 1000 },
        { description = "Full screen", outcome = "correct", reaction_ms = 950 },
        { description = "Close window", outcome = "correct", reaction_ms = 1050 },
      },
    })
  end
  for i = 1, 6 do
    text[#text + 1] = line({
      stamp = ("2026-06-1%dT09:00:00"):format(i),
      answers = {
        { description = "Terminal", outcome = "correct", reaction_ms = 2900 },
        { description = "Browser", outcome = "correct", reaction_ms = 3000 },
        { description = "Full screen", outcome = "correct", reaction_ms = 2950 },
        { description = "Close window", outcome = "correct", reaction_ms = 3050 },
      },
    })
  end
  local m = stats.model(table.concat(text, "\n"))
  eq("getting worse is reported as getting worse", "slower", m.trend.verdict)
  truthy("with the regression measured", m.trend.paired.median_delta_ms >= 1500)
end

-- --- noise is not progress -------------------------------------------------
do
  local text = {}
  for i = 1, 12 do
    -- A few milliseconds apart, alternating direction. Nothing happened.
    local jitter = (i % 2 == 0) and 20 or -20
    text[#text + 1] = line({
      stamp = ("2026-06-%02dT09:00:00"):format(i),
      answers = {
        { description = "Terminal", outcome = "correct", reaction_ms = 1500 + jitter },
        { description = "Browser", outcome = "correct", reaction_ms = 1600 + jitter },
        { description = "Full screen", outcome = "correct", reaction_ms = 1400 + jitter },
        { description = "Close window", outcome = "correct", reaction_ms = 1550 + jitter },
      },
    })
  end
  local m = stats.model(table.concat(text, "\n"))
  eq("a flat career reads as steady", "steady", m.trend.verdict)
end

-- --- a walk-away is not a reaction time ------------------------------------
do
  local text = {}
  for i = 1, 6 do
    text[#text + 1] = line({
      stamp = ("2026-06-0%dT09:00:00"):format(i),
      answers = {
        { description = "Terminal", outcome = "correct", reaction_ms = 1000 },
        { description = "Browser", outcome = "correct", reaction_ms = 1100 },
        { description = "Full screen", outcome = "correct", reaction_ms = 1200 },
        -- Went to lunch mid-prompt. Nine minutes is not a reaction.
        { description = "Close window", outcome = "correct", reaction_ms = 540000 },
      },
    })
  end
  local m = stats.model(table.concat(text, "\n"))
  truthy("a nine-minute answer does not become the typical time",
    m.lifetime.median_ms and m.lifetime.median_ms < 2000)
  local checked = false
  for _, r in ipairs(m.records) do
    if r.label == "top speed" then
      checked = true
      local v = tonumber(r.value:match("%d+"))
      -- The speedometer's own ceiling. A nine-minute answer scores zero rather
      -- than a plausible-looking number, so a record that survived the filter
      -- has to sit inside the range the rest of the game uses.
      truthy("and the records stay believable", v > 0 and v <= 250)
    end
  end
  truthy("the top speed record exists to be checked", checked)
end

-- --- one unit ---------------------------------------------------------------
--
-- The rest of the game has spoken km/h since the first stage: the HUD, the
-- results page, the tiers, the trophies. A career screen reporting milliseconds
-- made the one place you go to compare yourself to yourself the one place using
-- a different unit, so the same answer looked like two different events
-- depending on which screen you read it on.
--
-- Milliseconds stay inside the model, where the arithmetic happens. This is the
-- assertion that keeps them there.
do
  local m = stats.model(FIXTURE)
  local text = screens.text(m)
  local offenders = {}
  for rendered in text:gmatch("[^\n]+") do
    if rendered:find("%d%s*ms") then offenders[#offenders + 1] = rendered end
  end
  eq("nothing the reader sees is in milliseconds", "", table.concat(offenders, " / "))
  truthy("and the pace is reported in km/h", text:find("km/h", 1, true) ~= nil)

  -- The paired pair is DERIVED from the verdict's own statistic, so the two can
  -- never disagree. Stated as a test because the obvious implementation --
  -- taking each window's median separately -- can print "FASTER" above a pair
  -- of speeds that got slower.
  local p = m.trend.paired
  if m.trend.verdict == "faster" then
    truthy("a faster verdict shows a faster pair", p.after_kmh > p.before_kmh)
  elseif m.trend.verdict == "slower" then
    truthy("a slower verdict shows a slower pair", p.after_kmh < p.before_kmh)
  end
end

-- --- the golden ------------------------------------------------------------
--
-- One fixture career, one exact rendering. Same contract as the screens and the
-- cabinet: the model must format to precisely this text, so a change to either
-- side shows up as a diff rather than as a screen nobody looked at.
do
  local m = stats.model(FIXTURE)
  local actual = screens.text(m)
  local golden = read(HERE .. "fixtures/stats/expected.txt")
  if not golden then
    fail("a golden exists", "test/fixtures/stats/expected.txt",
         "missing -- run lua test/capture-stats.lua")
  elseif actual == golden then
    ok("the fixture career renders exactly as captured")
  else
    local a, b = {}, {}
    for l in golden:gmatch("[^\n]*") do a[#a + 1] = l end
    for l in actual:gmatch("[^\n]*") do b[#b + 1] = l end
    local where = "identical"
    for i = 1, math.max(#a, #b) do
      if a[i] ~= b[i] then
        where = ("line %d\n         golden: %q\n         actual: %q"):format(
          i, tostring(a[i]), tostring(b[i]))
        break
      end
    end
    fail("the fixture career renders exactly as captured", "byte-identical", where)
  end

  -- Facts about the fixture worth stating separately from the golden, because a
  -- golden tells you something changed and not what was meant to be true.
  eq("the bail is left out of the chart", 12, #m.series)
  eq("but counted as a stage played", 13, m.lifetime.stages)
  eq("two courses show up", 2, #m.courses)
  eq("most-played first", "daily-driver", m.courses[1].course)
  truthy("the player improved", m.trend.verdict == "faster")
  -- Measured as a proportion of pace, not a width in km/h. km/h is a
  -- reciprocal, so the same steadiness of hand covers a wider band of it the
  -- faster you get, and a width would have marked this player DOWN for the
  -- improvement the line above asserts.
  truthy("and their answers tightened", m.trend.tighter)
  truthy("which is a fall in relative spread",
    m.trend.recent.spread_pct < m.trend.early.spread_pct)
end

print()
if failed == 0 then
  print(("\27[32mstats: %d passed\27[0m"):format(run))
  os.exit(0)
end
print(("\27[31mstats: %d of %d FAILED\27[0m"):format(failed, run))
os.exit(1)

-- Tests for lib/cabinet.lua, the reading of the trophy case.
-- Run directly:  lua test/test-cabinet.lua
--
-- trophies.lua owns what is EARNED and has its own suite. This owns what is
-- SHOWN about it, which is a different question with its own ways to be wrong:
-- a tier held but reported as missing, a per-course trophy counted as done on
-- the strength of one easy course, a locked entry hidden instead of dimmed.
--
-- Pure input to pure output, so none of it needs a compositor or a file.

package.path = (arg[0]:match("(.*/)") or "./") .. "../lib/?.lua;" .. package.path
local T = require("trophies")
local C = require("cabinet")

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

local COURSES = { "daily-driver", "the-commute", "track-day" }

local function find(model, id)
  for _, sec in ipairs(model.sections) do
    for _, r in ipairs(sec.rows) do
      if r.id == id then return r, sec end
    end
  end
end

-- Any repeatable and any milestone, taken from the catalog rather than named,
-- so these tests do not break every time a trophy is added or renamed.
local function first_of(class)
  for _, t in ipairs(T.CATALOG) do
    if t.class == class then return t end
  end
end

print("cabinet:")

-- --- an empty cabinet is the roadmap ---------------------------------------
do
  local m = C.model(T.new_cabinet(), COURSES)
  truthy("an empty cabinet still has sections", #m.sections > 0)

  local rows = 0
  for _, sec in ipairs(m.sections) do rows = rows + #sec.rows end
  -- Every trophy EXCEPT the hidden ones. The empty case is the roadmap, and a
  -- secret trophy is the reward for having finished the map: putting it on the
  -- map is telling someone about the door at the end of a corridor they have
  -- not walked yet.
  local visible = 0
  for _, t in ipairs(T.CATALOG) do
    if not t.hidden then visible = visible + 1 end
  end
  truthy("and still lists every trophy that is not secret", rows == visible)
  truthy("and there IS a secret one to leave out", visible < #T.CATALOG)

  local leaked = {}
  for _, sec in ipairs(m.sections) do
    for _, r in ipairs(sec.rows) do
      if T.by_id(r.id) and T.by_id(r.id).hidden then leaked[#leaked + 1] = r.id end
    end
  end
  eq("and the secret one is not among them", "", table.concat(leaked, ", "))
  -- Including in the arithmetic. "12 of 44" on a case that lists forty-three is
  -- the same spoiler as listing it, told with a number instead. The total is
  -- not the row count, because a per-course trophy counts once per course, so
  -- the check is that unlocking the secret moves it by exactly one.
  local secret
  for _, t in ipairs(T.CATALOG) do
    if t.hidden then secret = t break end
  end
  local unlocked = T.new_cabinet()
  unlocked.earned[T.key(secret)] = "2026-08-27"
  eq("nor in the total until it is won", 1,
     C.model(unlocked, COURSES).summary.total - m.summary.total)
  eq("with nothing won", 0, m.summary.won)
  truthy("but a total to aim at", m.summary.total > 0)

  -- The whole point of the screen for a new player: what is NOT won has to be
  -- visible, or the cabinet stops being a roadmap and becomes a receipt.
  local unwon = 0
  for _, sec in ipairs(m.sections) do
    for _, r in ipairs(sec.rows) do
      if not r.won then unwon = unwon + 1 end
    end
  end
  eq("every trophy shows as unwon rather than being hidden", rows, unwon)
end

-- --- sections come in reading order ----------------------------------------
do
  local m = C.model(T.new_cabinet(), COURSES)
  local order = {}
  for _, sec in ipairs(m.sections) do order[#order + 1] = sec.class end
  eq("hardest-to-earn first", "milestone|mastery|repeatable|streak", table.concat(order, "|"))
  truthy("and every section is labeled", m.sections[1].label ~= nil)
end

-- --- repeatables report the tier they hold and the one they are chasing -----
do
  local rep = first_of("repeatable")
  local saved = T.new_cabinet()
  saved.counts[rep.id] = T.TIERS[1].at          -- exactly the bronze threshold

  local m = C.model(saved, COURSES)
  local row = find(m, rep.id)
  truthy("a repeatable at the first threshold is won", row.won)
  eq("and holds that tier", T.TIERS[1].name, row.tiered.tier)
  eq("and is chasing the next", T.TIERS[2].at, row.tiered.next_at)
  truthy("with progress toward it", row.tiered.progress > 0 and row.tiered.progress < 1)
  truthy("and is not maxed", not row.tiered.maxed)
end

-- Won, but holding no tier yet. Repeatables cannot show this because their
-- bronze sits at 1, so the FIRST version of this test asserted it against one
-- and failed: a count of 1 is already bronze. Streaks are where the state is
-- real, because their bronze is further out, and it is what the cabinet shows
-- as "Compound Interest 2/3 to bronze" with an empty chip.
do
  local streak = first_of("streak")
  local below = T.STREAK_TIERS[1].at - 1
  truthy("streak bronze is far enough out to have a below-bronze state", below >= 1)

  local saved = T.new_cabinet()
  saved.counts[streak.id] = below

  local row = find(C.model(saved, COURSES), streak.id)
  truthy("a part-built streak counts as won", row.won)
  eq("but holds no tier yet", nil, row.tiered.tier)
  eq("and is chasing bronze", T.STREAK_TIERS[1].at, row.tiered.next_at)
end

do
  local rep = first_of("repeatable")
  local saved = T.new_cabinet()
  saved.counts[rep.id] = T.TIERS[#T.TIERS].at * 10   -- far past the top

  local row = find(C.model(saved, COURSES), rep.id)
  eq("past the top tier it holds the top", T.TIERS[#T.TIERS].name, row.tiered.tier)
  truthy("and reads as maxed", row.tiered.maxed)
  -- A finished thing has no progress left to show, and a bar stuck at 100%
  -- forever is worse than no bar.
  eq("with no progress bar to draw", nil, row.tiered.progress)
end

-- --- mastery is per course, and that is the anti-grinding rule --------------
do
  local mast
  for _, t in ipairs(T.CATALOG) do
    if t.class == "mastery" then mast = t break end
  end

  local saved = T.new_cabinet()
  saved.earned[mast.id .. "@" .. COURSES[1]] = "2026-08-25"

  local row = find(C.model(saved, COURSES), mast.id)
  eq("winning it on one course counts as one", 1, row.held)
  eq("out of every course", #COURSES, row.of)
  truthy("it shows as started", row.won)
  -- Grinding the easy course is not mastery. This is the rule that says so.
  truthy("but not as complete", not row.complete)

  for _, c in ipairs(COURSES) do saved.earned[mast.id .. "@" .. c] = "2026-08-26" end
  local all = find(C.model(saved, COURSES), mast.id)
  eq("winning it everywhere completes it", #COURSES, all.held)
  truthy("and it reads as complete", all.complete)
end

-- --- the summary counts what the sections show -----------------------------
do
  local saved = T.new_cabinet()
  local rep = first_of("repeatable")
  saved.counts[rep.id] = 5
  saved.days = { "2026-08-25", "2026-08-26" }

  local m = C.model(saved, COURSES)
  eq("the summary counts the days played", 2, m.summary.days)
  eq("and names the most recent", "2026-08-26", m.summary.last_day)

  -- The footer number has to agree with the shelves, or the screen argues with
  -- itself in front of the person reading it.
  local won = 0
  for _, sec in ipairs(m.sections) do
    for _, r in ipairs(sec.rows) do won = won + (r.held or 0) end
  end
  eq("and the total won matches the rows", won, m.summary.won)
end

-- --- every trophy says what it means -------------------------------------
--
-- A case full of phrases nobody can decode is a wall of nicknames: "Cache Hit"
-- and "Sharp Knives" say nothing about what you did. The note was already in
-- the catalog and was hidden behind --why alongside the attribution, which is
-- the one part that genuinely had to stay off the badge face.
do
  local m = C.model(T.new_cabinet(), COURSES)
  local without = {}
  for _, sec in ipairs(m.sections) do
    for _, r in ipairs(sec.rows) do
      if (r.note or "") == "" then without[#without + 1] = r.id end
    end
  end
  eq("every trophy carries a note", "", table.concat(without, ", "))

  -- The badge elides, so a note that runs long loses its end rather than
  -- wrapping: "a curated course run exactly as designed: clean, u..." told a
  -- reader less than nothing. Measured against the narrowest shelf.
  local LIMIT = 45
  local long = {}
  for _, t in ipairs(T.CATALOG) do
    if #t.note > LIMIT then long[#long + 1] = ("%s (%d)"):format(t.id, #t.note) end
  end
  eq("and one short enough to read on a badge", "", table.concat(long, ", "))

  -- John's rule, repo-wide. It also happens to be where a badge cuts: the
  -- clause after the dash is the half that gets elided away.
  -- Needles built from bytes rather than written out, so this file does not
  -- contain the characters it exists to forbid. The tree-wide check in
  -- test-wiring.sh greps for them, and a literal here would fail that one.
  local EM, EN = string.char(226, 128, 148), string.char(226, 128, 147)
  local dashed = {}
  for _, t in ipairs(T.CATALOG) do
    if t.note:find(EM, 1, true) or t.note:find(EN, 1, true) then
      dashed[#dashed + 1] = t.id
    end
  end
  eq("with no em dashes", "", table.concat(dashed, ", "))
end

-- --- attribution travels with the row, off the badge face ------------------
do
  local m = C.model(T.new_cabinet(), COURSES)
  local with_source = 0
  for _, sec in ipairs(m.sections) do
    for _, r in ipairs(sec.rows) do
      if r.source then with_source = with_source + 1 end
    end
  end
  truthy("rows carry their source for --why to show", with_source > 0)
end

-- --- it survives a cabinet with nothing in it ------------------------------
do
  local m = C.model(nil, nil)
  truthy("a nil cabinet does not error", #m.sections > 0)
  eq("and the screen names itself", "cabinet", m.screen)
  -- No courses means per-course trophies are 0 of 0, which must not become a
  -- division or a false "complete".
  local mast
  for _, sec in ipairs(m.sections) do
    for _, r in ipairs(sec.rows) do
      if r.per_course then mast = r break end
    end
  end
  if mast then
    eq("a per-course trophy with no courses is 0 of 0", 0, mast.of)
    truthy("and is not silently complete", not mast.complete)
  else
    ok("no per-course trophies to check")
  end
end

print()
if failed == 0 then
  print(("\27[32mcabinet: %d passed\27[0m"):format(run))
  os.exit(0)
end
print(("\27[31mcabinet: %d of %d FAILED\27[0m"):format(failed, run))
os.exit(1)

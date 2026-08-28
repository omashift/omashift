-- The Cabinet, as data.
--
--   cabinet.model(saved, courses) -> { screen = "cabinet", sections = {...}, ... }
--
-- WHY THIS IS ITS OWN FILE
--
-- The trophy case used to be computed and formatted in one pass, inside a bash
-- heredoc in bin/omashift-cabinet. That made it a terminal feature rather than a
-- feature: the visual cabinet the design asks for could not reuse a line of it,
-- and would have meant a second implementation of every rule about what counts
-- as won.
--
-- This is the same split the screens took. `trophies.lua` owns the RULES (what
-- is earned), this owns the READING (what to show about it), and `screens.lua`
-- and the overlay each turn that reading into pixels. Nothing here formats
-- anything: no padding, no brackets, no columns.
--
-- Dependency-free on purpose, like trophies.lua. No clock, no filesystem, no
-- core.lua. The caller supplies the saved cabinet and the list of courses, which
-- is everything a reading needs.

local T = require("trophies")

local M = {}

-- Order is the reading order, hardest-to-earn first. A new player opening a
-- mostly-empty cabinet should meet the once-ever prizes before the grind.
M.CLASS_ORDER = { "secret", "milestone", "mastery", "repeatable", "streak" }

M.CLASS_LABEL = {
  secret     = "SECRET: everything else, at its ceiling",
  milestone  = "MILESTONES: once, ever",
  mastery    = "MASTERY: one per course",
  repeatable = "REPEATABLES: bronze / silver / gold",
  streak     = "STREAKS: consecutive days",
}

-- Which tier of a repeatable is held, and what the next one costs.
local function tiered(count, tiers)
  local have = T.tier_for_count(count, tiers)
  local nxt
  for _, t in ipairs(tiers) do
    if count < t.at then nxt = t break end
  end
  return {
    tier = have,                       -- "bronze" | "silver" | "gold" | nil
    count = count,
    next_at = nxt and nxt.at or nil,
    next_tier = nxt and nxt.name or nil,
    maxed = nxt == nil,
    -- How far into the current step, for anything that wants to draw a bar.
    -- Nil when maxed, because a finished thing has no progress left to show.
    progress = nxt and (count / nxt.at) or nil,
  }
end

-- One reading of the whole cabinet.
--
-- Every row carries `won` (is there anything to celebrate) and `held`/`of` (how
-- much of it), so a renderer never has to know the difference between a tiered
-- repeatable, a per-course mastery and a one-off milestone in order to decide
-- whether to light it up.
function M.model(saved, courses)
  saved = saved or T.new_cabinet()
  courses = courses or {}
  local counts, earned = saved.counts or {}, saved.earned or {}

  local sections, total, won_total = {}, 0, 0

  for _, class in ipairs(M.CLASS_ORDER) do
    local rows = {}
    for _, t in ipairs(T.CATALOG) do
      -- HIDDEN MEANS HIDDEN, INCLUDING FROM THE ARITHMETIC. Every other trophy
      -- shows unearned and dimmed, because the empty case is the roadmap. A
      -- secret one is left out entirely until it is won, and left out of the
      -- totals with it: "12 of 44" on a case that only lists forty-three is the
      -- same spoiler as listing it, told by a number instead.
      local shown = (not t.hidden) or (earned[T.key(t)] ~= nil)
      if t.class == class and shown then
        local row = {
          id = t.id,
          phrase = t.phrase,
          class = t.class,
          -- Attribution deliberately off the badge face. `note` and `source`
          -- travel with the row so `--why` can show them, but a renderer that
          -- ignores them is showing the cabinet correctly: a permanent display
          -- that named its references would read as a patron endorsement.
          note = t.note,
          source = t.source,
          -- A trophy that cannot be won yet because whatever it depends on does
          -- not exist. Kept in the catalog on purpose: the empty state is the
          -- roadmap, which matters most to a new player.
          locked = t.locked,
        }

        if class == "repeatable" or class == "streak" then
          local tiers = (class == "streak") and T.STREAK_TIERS or T.TIERS
          local count = counts[t.id] or 0
          row.tiered = tiered(count, tiers)
          row.won = count > 0
          row.held = row.won and 1 or 0
          row.of = 1
          total = total + 1
          if row.won then won_total = won_total + 1 end

        elseif t.class == "mastery" or t.per_course then
          -- Reported as a fraction because that IS the rule: winning Direct
          -- Drive on Daily Driver alone is 1 of 3, not done. Grinding the easy
          -- course is not mastery.
          local have = 0
          local per = {}
          for _, c in ipairs(courses) do
            local day = earned[t.id .. "@" .. c]
            per[#per + 1] = { course = c, day = day }
            if day then have = have + 1 end
          end
          row.per_course = per
          row.held = have
          row.of = #courses
          row.won = have > 0
          row.complete = (#courses > 0) and (have == #courses)
          total = total + #courses
          won_total = won_total + have

        else
          local day = earned[t.id]
          row.day = day
          row.won = day ~= nil
          row.held = row.won and 1 or 0
          row.of = 1
          total = total + 1
          if row.won then won_total = won_total + 1 end
        end

        rows[#rows + 1] = row
      end
    end

    if #rows > 0 then
      sections[#sections + 1] = {
        class = class,
        label = M.CLASS_LABEL[class],
        rows = rows,
      }
    end
  end

  local days = saved.days or {}
  return {
    screen = "cabinet",
    sections = sections,
    summary = {
      won = won_total,
      total = total,
      days = #days,
      last_day = (#days > 0) and days[#days] or nil,
    },
  }
end

return M

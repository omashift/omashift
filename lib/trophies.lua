-- The Cabinet: trophies earned from finished stages.
--
-- Deliberately dependency-free. It takes a plain description of what happened in
-- a stage and a plain cabinet table, and returns what was earned. No clock, no
-- filesystem, no core.lua. That is what makes every rule below testable without
-- a compositor, which is the same split core.lua has from engine.lua.
--
-- WHY TROPHIES ARE NOT JUST THE PRAISE PHRASES
--
-- A popup can be loose; a trophy needs a crisp earn condition. `Zero Latency`
-- fires on a single fast answer and would be worth nothing as a badge, dozens
-- of them a session. Tiering it 1/10/50 keeps the phrase and makes it a progression.
-- That is the whole reason there are four classes rather than one list.

local T = {}

-- Bronze/silver/gold by count. The gaps are wide on purpose: silver should take
-- a few sessions and gold should take weeks, or the cabinet fills in a day and
-- stops being a reason to come back.
T.TIERS = {
  { name = "bronze", at = 1 },
  { name = "silver", at = 10 },
  { name = "gold",   at = 50 },
}

-- Streaks count DAYS, so the thresholds are far lower. 30 consecutive days is
-- already a serious commitment; 50 would be a punishment.
T.STREAK_TIERS = {
  { name = "bronze", at = 3 },
  { name = "silver", at = 7 },
  { name = "gold",   at = 30 },
}

-- Courses that are hand-curated, as opposed to generated from your history.
-- `Omakase` means running a menu exactly as it was designed, which only makes
-- sense for a menu somebody designed.
local function is_curated(course)
  return course ~= nil and course ~= "" and course ~= "all" and course ~= "blind-spots"
end

-- Longest run of consecutive answers that were correct AND not slow. "Presence"
-- is about flow, so a slow-but-correct answer breaks it the same way the
-- gearbox's momentum chain breaks.
local function longest_flow(results, slow_tier)
  local best, run = 0, 0
  for _, r in ipairs(results or {}) do
    if r.outcome == "correct" and r.tier ~= (slow_tier or "slow") then
      run = run + 1
      if run > best then best = run end
    else
      run = 0
    end
  end
  return best
end

local function count_tier(results, name)
  local n = 0
  for _, r in ipairs(results or {}) do
    if r.outcome == "correct" and r.tier == name then n = n + 1 end
  end
  return n
end

-- Every trophy. `count` returns how many times a repeatable happened this stage;
-- `earned` returns true for a one-off. Mastery entries are scoped per course by
-- the caller, so the same phrase can be earned once on each menu.
--
-- A `locked` field marks a trophy that cannot be won yet because whatever it
-- depends on does not exist. Locked entries stay in the catalog on purpose:
-- the cabinet doubles as the roadmap. Nothing is locked today. The last two
-- were waiting on the Endurance course, which now ships.
T.CATALOG = {
  -- ---- repeatables, tiered by count -------------------------------------
  { id = "zero-latency", phrase = "Zero Latency", class = "repeatable",
    note = "answers under the top threshold",
    source = "Matthew Prince, Cloudflare",
    count = function(ctx) return count_tier(ctx.results, "zero-latency") end },

  { id = "on-rails", phrase = "You're On Rails", class = "repeatable",
    note = "answers in the second tier or better",
    source = "DHH: Rails, and racing",
    count = function(ctx) return count_tier(ctx.results, "on-rails") end },

  { id = "cache-hit", phrase = "Cache Hit", class = "repeatable",
    note = "recalling a binding you had previously missed",
    source = "Matthew Prince, Cloudflare: CDN caching",
    count = function(ctx)
      local n = 0
      for _, r in ipairs(ctx.results or {}) do
        if r.outcome == "correct" and (ctx.previously_missed or {})[r.description] then
          n = n + 1
        end
      end
      return n
    end },

  { id = "fast-off-the-blocks", phrase = "Fast Off The Blocks", class = "repeatable",
    note = "the first three notes correct",
    source = "Jack Dorsey, Block",
    count = function(ctx)
      local rs = ctx.results or {}
      if #rs < 3 then return 0 end
      for i = 1, 3 do
        if rs[i].outcome ~= "correct" then return 0 end
      end
      return 1
    end },

  { id = "presence", phrase = "Presence", class = "repeatable",
    note = "six in a row with no hesitation",
    source = "Brendan Iribe: presence, Oculus's term of art",
    count = function(ctx) return longest_flow(ctx.results) >= 6 and 1 or 0 end },

  { id = "rework", phrase = "Rework", class = "repeatable",
    note = "beating your own previous average on a course",
    source = "Jason Fried, 37signals: Rework",
    count = function(ctx)
      local now, before = ctx.summary and ctx.summary.average_ms, ctx.previous_course_average
      if not now or not before then return 0 end
      return now < before and 1 or 0
    end },

  -- ---- mastery, one per course ------------------------------------------
  { id = "conversion-rate", phrase = "Conversion Rate: 100%", class = "mastery",
    note = "every note correct, co-driver allowed",
    source = "Tobi Lütke, Shopify",
    earned = function(ctx)
      local s = ctx.summary
      return s ~= nil and s.offs == 0 and s.correct == s.prompts and s.prompts > 0
    end },

  { id = "getting-real", phrase = "Getting Real", class = "mastery",
    note = "a course completed clean",
    source = "Jason Fried, 37signals: Getting Real",
    earned = function(ctx)
      return ctx.completed == true and ctx.summary ~= nil and ctx.summary.clean == true
    end },

  { id = "direct-drive", phrase = "Direct Drive", class = "mastery",
    note = "clean, and no co-driver called",
    source = "Michael Dell: the Direct Model; also direct-drive wheelbases",
    earned = function(ctx)
      return ctx.completed == true and ctx.assisted == false
        and ctx.summary ~= nil and ctx.summary.clean == true
    end },

  -- ---- milestones, once ever --------------------------------------------
  { id = "open-sesame", phrase = "Open Sesame", class = "milestone", per_course = true,
    note = "finishing a course for the first time",
    source = "Brendan Iribe, Sesame",
    earned = function(ctx) return ctx.completed == true end },

  { id = "built-to-order", phrase = "Built To Order", class = "milestone",
    note = "finishing a Blind Spots stage",
    source = "Michael Dell: build-to-order manufacturing",
    earned = function(ctx) return ctx.completed == true and ctx.course == "blind-spots" end },

  { id = "omakase", phrase = "Omakase", class = "milestone",
    note = "a curated course, clean and unaided",
    source = "DHH: Rails Doctrine; also the origin of Omarchy's own name",
    earned = function(ctx)
      local s = ctx.summary
      return ctx.completed == true and is_curated(ctx.course) and ctx.assisted == false
        and s ~= nil and s.clean == true and (s.requeues or 0) == 0
    end },

  -- The endgame pair. Endurance is the rare far corners of the keymap, and
  -- DHH is a genuine Le Mans class winner, so the names are not decoration.
  { id = "sharp-knives", phrase = "Sharp Knives", class = "milestone",
    note = "finishing the Endurance course",
    source = "DHH: Rails Doctrine, \"provide sharp knives\"",
    earned = function(ctx) return ctx.completed == true and ctx.course == "endurance" end },

  { id = "class-win", phrase = "Class Win", class = "milestone",
    note = "a clean Endurance run",
    source = "endurance racing",
    earned = function(ctx)
      return ctx.completed == true and ctx.course == "endurance"
        and ctx.summary ~= nil and ctx.summary.clean == true
    end },

  -- ---- streaks, tiered by consecutive days ------------------------------
  { id = "compound-interest", phrase = "Compound Interest", class = "streak",
    note = "playing on consecutive days",
    source = "Michael Dell: Invest America, where accounts compound until 18" },

  -- ---- secret, and it stays that way ------------------------------------
  --
  -- THE ONLY TROPHY THAT IS NOT ON THE ROADMAP. Every other entry shows in the
  -- cabinet unearned, dimmed, because the empty case is the map of what there
  -- is to do. This one is deliberately absent until it is won: it is the
  -- reward for having already finished the map, so putting it on the map would
  -- be telling someone about a door at the end of a corridor they have not
  -- walked yet. `hidden` is what cabinet.lua reads to leave it out, and the
  -- totals leave it out too, so the count cannot leak a forty-fourth trophy.
  --
  -- It is not judged from a stage. Every other rule here reads what happened in
  -- one run; this one reads the CASE, so `unlocked` takes the cabinet instead
  -- of a stage context and runs in its own pass after the rest have recorded.
  { id = "oligarchy", phrase = "Oligarchy", class = "secret", hidden = true,
    -- AT the redline, not beyond it. Beyond is over-revving, which is how you
    -- destroy an engine, and this trophy is for reaching a maximum rather than
    -- exceeding one. Getting that wrong is visible to exactly the people the
    -- rally vocabulary is aimed at, which is the same reason the shift gate
    -- moves through neutral instead of across the crossbar.
    note = "every other trophy, at the redline",
    source = "only a few will make it, and a word that was one letter away already",
    unlocked = function(cabinet, courses) return T.is_topped_out(cabinet, courses) end },
}

function T.by_id(id)
  for _, t in ipairs(T.CATALOG) do
    if t.id == id then return t end
  end
  return nil
end

-- An empty cabinet. `counts` is how many times each repeatable has happened,
-- `earned` maps a trophy key to the day it was first earned, and `days` is the
-- set of days played, which is all a streak needs.
function T.new_cabinet()
  return { counts = {}, earned = {}, days = {} }
end

-- Mastery and per-course milestones are scoped, so the same phrase can be won
-- once on each menu. Everything else is global.
function T.key(trophy, course)
  if trophy.class == "mastery" or trophy.per_course then
    return trophy.id .. "@" .. tostring(course or "all")
  end
  return trophy.id
end

-- Is everything else in the case at its ceiling?
--
-- Gold on every repeatable, gold on the streak, every mastery on every course,
-- every milestone. Read from `earned` rather than from `counts`, because a tier
-- once crossed is a permanent fact and a streak's count is the run you are on
-- right now: checking counts would take Oligarchy away again the first day you
-- missed, which is not what a trophy is.
--
-- LOCKED ENTRIES ARE SKIPPED. A trophy that cannot be won yet because whatever
-- it depends on does not exist would make this unwinnable for everyone, and it
-- would be unwinnable silently.
--
-- No courses means no answer. An empty course list would otherwise satisfy
-- "earned on every course" vacuously and hand out the endgame trophy for
-- nothing.
function T.is_topped_out(cabinet, courses)
  if type(cabinet) ~= "table" then return false end
  if type(courses) ~= "table" or #courses == 0 then return false end
  local earned = cabinet.earned or {}

  local top_repeat = T.TIERS[#T.TIERS].name
  local top_streak = T.STREAK_TIERS[#T.STREAK_TIERS].name

  for _, trophy in ipairs(T.CATALOG) do
    if trophy.class ~= "secret" and not trophy.locked then
      if trophy.class == "repeatable" then
        if not earned[T.key(trophy) .. "@" .. top_repeat] then return false end
      elseif trophy.class == "streak" then
        if not earned[T.key(trophy) .. "@" .. top_streak] then return false end
      elseif trophy.class == "mastery" or trophy.per_course then
        for _, course in ipairs(courses) do
          if not earned[T.key(trophy, course)] then return false end
        end
      else
        if not earned[T.key(trophy)] then return false end
      end
    end
  end
  return true
end

-- Highest tier reached at this count, or nil below the first threshold.
function T.tier_for_count(count, tiers)
  local reached
  for _, tier in ipairs(tiers or T.TIERS) do
    if (count or 0) >= tier.at then reached = tier.name end
  end
  return reached
end

-- "2026-08-25" -> a day number, so consecutive-ness is subtraction.
-- Stored as dates rather than numbers because this file is meant to be read by
-- a human, which is the whole stance the cabinet takes about its own state.
function T.day_number(iso)
  local y, m, d = tostring(iso or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not y then return nil end
  local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  return t and math.floor(t / 86400) or nil
end

-- Consecutive days ending at `today`. A gap resets it; playing twice in one day
-- does not advance it, which is why days are a set rather than a counter.
function T.day_streak(days, today)
  local seen = {}
  for _, iso in ipairs(days or {}) do
    local n = T.day_number(iso)
    if n then seen[n] = true end
  end
  local cur = T.day_number(today)
  if not cur or not seen[cur] then return 0 end
  local run = 0
  while seen[cur - run] do run = run + 1 end
  return run
end

local function insert_day(cabinet, iso)
  for _, d in ipairs(cabinet.days) do
    if d == iso then return end
  end
  cabinet.days[#cabinet.days + 1] = iso
  table.sort(cabinet.days)
end

-- Record one finished stage. Mutates `cabinet` and returns the list of trophies
-- newly earned, each { id, key, phrase, tier, count, class }.
--
-- Only NEW earns are returned. A repeatable that ticks up without crossing a
-- threshold is progress, not an award. "first earn is the moment", and a popup
-- that fires on every increment would be the noise this design exists to avoid.
function T.record(cabinet, ctx)
  cabinet = cabinet or T.new_cabinet()
  cabinet.counts = cabinet.counts or {}
  cabinet.earned = cabinet.earned or {}
  cabinet.days = cabinet.days or {}
  ctx = ctx or {}

  local won = {}
  local day = ctx.day

  if day then insert_day(cabinet, day) end

  for _, trophy in ipairs(T.CATALOG) do
    local key = T.key(trophy, ctx.course)
    if trophy.class == "repeatable" then
      local n = trophy.count and trophy.count(ctx) or 0
      if n > 0 then
        local before = cabinet.counts[key] or 0
        local after = before + n
        cabinet.counts[key] = after
        local was, now = T.tier_for_count(before, T.TIERS), T.tier_for_count(after, T.TIERS)
        if now and now ~= was then
          cabinet.earned[key .. "@" .. now] = day
          won[#won + 1] = { id = trophy.id, key = key, phrase = trophy.phrase,
                            class = trophy.class, tier = now, count = after }
        end
      end
    elseif trophy.class == "streak" then
      local run = T.day_streak(cabinet.days, day)
      cabinet.counts[key] = run
      local now = T.tier_for_count(run, T.STREAK_TIERS)
      if now and not cabinet.earned[key .. "@" .. now] then
        cabinet.earned[key .. "@" .. now] = day
        won[#won + 1] = { id = trophy.id, key = key, phrase = trophy.phrase,
                          class = trophy.class, tier = now, count = run }
      end
    else
      if trophy.earned and trophy.earned(ctx) and not cabinet.earned[key] then
        cabinet.earned[key] = day
        won[#won + 1] = { id = trophy.id, key = key, phrase = trophy.phrase,
                          class = trophy.class, count = 1 }
      end
    end
  end

  -- SECRETS LAST, and in their own pass. They are judged on the case rather
  -- than on the stage, so they have to see this run's awards already recorded:
  -- the run that tops out the last repeatable is the run that unlocks this, and
  -- judging it alongside the others would make you play one more stage for
  -- something you had already earned.
  for _, trophy in ipairs(T.CATALOG) do
    if trophy.class == "secret" and trophy.unlocked then
      local key = T.key(trophy, ctx.course)
      if not cabinet.earned[key] and trophy.unlocked(cabinet, ctx.courses) then
        cabinet.earned[key] = day
        won[#won + 1] = { id = trophy.id, key = key, phrase = trophy.phrase,
                          class = trophy.class, count = 1, secret = true }
      end
    end
  end

  return won, cabinet
end

return T

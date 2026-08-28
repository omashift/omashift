-- The Logbook, as data.
--
--   stats.model(history_text) -> { screen = "stats", trend = {...}, ... }
--
-- WHAT THIS SCREEN IS FOR
--
-- One question, asked out loud: am I getting better? Everything here either
-- answers it or gets out of the way. The trophy case says WHAT you have done,
-- the in-play telemetry says how ONE stage went, and neither of them can tell
-- you whether last week's you would lose to today's.
--
-- WHY IT IS ITS OWN FILE, AND PURE
--
-- Same split as cabinet.lua, for the same reason. `core.lua` owns the raw
-- readings, this owns the READING OF THE READINGS, and screens.lua and the
-- overlay each turn that into pixels. No clock, no filesystem, no hl.*: hand it
-- the text of history.jsonl and it hands back a model. That is what lets the
-- whole thing be tested by calling it.
--
-- THE THREE WAYS A STATS SCREEN LIES, AND WHAT IS DONE ABOUT THEM
--
-- 1. COUNTING A WALK-AWAY AS A FAILURE. A retired stage records the prompts it
--    PLANNED, so a stage abandoned after one answer reads as 1/5 and drags the
--    trend down for something that was never played. Accuracy here is over
--    answers GIVEN, never over prompts planned, and a stage with fewer than
--    MIN_ANSWERS is left out of the trend entirely.
--
-- 2. COMPARING DIFFERENT WORK. Stage 3 was Daily Driver on easy; stage 40 was
--    Endurance on hard. "You got slower" is worthless if the questions got
--    harder. The headline trend is therefore backed by a PAIRED comparison:
--    only bindings the player has answered in both windows, each compared with
--    itself. That controls for which keys were asked, which is the confound
--    that matters.
--
-- WHAT UNIT THIS SCREEN SPEAKS
--
-- KILOMETERS PER HOUR, everywhere a player reads a number. The rest of the game
-- has spoken km/h since the first stage: the HUD, the results page, the tiers,
-- the trophies. A career screen that reported milliseconds made the one place
-- you go to compare yourself to yourself the one place that used a different
-- unit, so a personal best on the results page and the same answer in the
-- Logbook did not look like the same event.
--
-- Milliseconds stay INSIDE. They are the raw measurement, they are what a
-- median should be taken over, and the noise floor below is honest in ms and
-- would not be a constant in km/h. Every model field therefore carries both:
-- the ms for the arithmetic, the km/h for the reader. core.speed_kmh owns the
-- mapping, so the Logbook cannot disagree with the speedometer.
--
-- 3. DRESSING UP TOO LITTLE DATA. Two stages is not a trajectory. Every
--    comparison here reports the n it was computed from and refuses to render a
--    verdict below a threshold, because a stats screen that always has an
--    opinion teaches the player to ignore it.

local core = require("core")

local M = {}

-- A stage with fewer answers than this is a bail, not a data point.
M.MIN_ANSWERS = 3

-- How many recent stages count as "lately". Small enough to move within a
-- session, big enough that one bad stage does not own the verdict.
M.WINDOW = 5

-- Below this there is no trajectory to report, only noise.
M.MIN_TREND_STAGES = 6

-- A paired comparison needs enough shared bindings to mean anything.
M.MIN_PAIRS = 4

-- How much change is worth calling a change. Reaction times are noisy at the
-- 50 ms scale and a screen that announces a 12 ms improvement as progress is
-- lying with a true number.
M.MEANINGFUL_MS = 100

-- The speedometer, borrowed rather than reimplemented. Every number a player
-- reads on this screen goes through here.
local function kmh(ms)
  if ms == nil then return nil end
  return core.speed_kmh(ms)
end

-- --- small statistics -------------------------------------------------------

local function round(x) return math.floor(x + 0.5) end

local function sorted_copy(t)
  local out = {}
  for i = 1, #t do out[i] = t[i] end
  table.sort(out)
  return out
end

-- The median, not the mean. One answer where the player looked away and came
-- back is worth 20 seconds and moves a mean by more than a whole stage of real
-- improvement moves it back.
local function median(values)
  if #values == 0 then return nil end
  local s = sorted_copy(values)
  local n = #s
  if n % 2 == 1 then return s[(n + 1) / 2] end
  return math.floor((s[n / 2] + s[n / 2 + 1]) / 2)
end

local function percentile(values, p)
  if #values == 0 then return nil end
  local s = sorted_copy(values)
  local i = math.floor(p * (#s - 1)) + 1
  return s[math.max(1, math.min(#s, i))]
end

-- How tightly the answers cluster. A player who is getting better gets more
-- CONSISTENT before they get faster, and the median alone cannot show that.
local function spread(values)
  local lo, hi = percentile(values, 0.25), percentile(values, 0.75)
  if not lo or not hi then return nil end
  return hi - lo
end

-- The same band as a PROPORTION of the pace it sits around, which is the one
-- form of it that can be compared across two windows fairly.
--
-- Not a km/h width, which was the obvious way to keep the screen in one unit
-- and is a trap: km/h is a reciprocal, so the same steadiness of hand covers a
-- wider band of km/h the faster you get. Measured that way, a player who
-- improves looks less consistent for improving, and "clustering tighter"
-- becomes a thing almost nobody can earn. A proportion has no such bias, and it
-- is not a rival unit either: it is a percentage OF the km/h figure beside it.
local function spread_pct(values)
  local band = spread(values)
  local mid = median(values)
  if not band or not mid or mid == 0 then return nil end
  return round(100 * band / mid)
end


local function pct(part, whole)
  if not whole or whole == 0 then return nil end
  return round(100 * part / whole)
end

-- --- reading one run --------------------------------------------------------

local function day_of(stamp)
  return tostring(stamp or ""):match("^(%d%d%d%d%-%d%d%-%d%d)")
end

-- A reaction we are willing to believe. Above the blind-spot ceiling the player
-- was away from the keyboard, not thinking, and core already owns that number.
local function real_ms(ms)
  return type(ms) == "number" and ms > 0 and ms < core.BLIND_SPOT.max_ms
end

-- One run, reduced to what the screen needs. ACCURACY IS OVER ANSWERS GIVEN.
local function read_run(run, index)
  local answered, correct, times = 0, 0, {}
  for _, a in ipairs(run.answers or {}) do
    answered = answered + 1
    if a.outcome == "correct" then
      correct = correct + 1
      if real_ms(a.reaction_ms) then times[#times + 1] = a.reaction_ms end
    end
  end
  return {
    index = index,
    stamp = run.stamp,
    day = day_of(run.stamp),
    course = run.course,
    label = run.course and core.course_label(run.course) or "all",
    difficulty = run.difficulty,
    answered = answered,
    -- What the stage MEANT to ask, kept apart from what it got round to
    -- asking. Nothing computes accuracy from this; it exists so a retirement
    -- can say what it walked away from.
    planned = tonumber(run.prompts),
    correct = correct,
    accuracy = pct(correct, answered),
    median_ms = median(times),
    median_kmh = kmh(median(times)),
    spread_ms = spread(times),
    spread_pct = spread_pct(times),
    times = times,
    assisted = run.assisted == true,
    completed = run.completed == true,
    clean = run.clean == true,
    -- Whether this run is allowed to speak about the trend at all.
    counts = answered >= M.MIN_ANSWERS,
  }
end

-- --- the trend --------------------------------------------------------------

-- Everything correct and believable in a set of runs, as one bag of times.
local function times_of(runs)
  local out = {}
  for _, r in ipairs(runs) do
    for _, ms in ipairs(r.times) do out[#out + 1] = ms end
  end
  return out
end

local function window_stats(runs, label)
  local answered, correct = 0, 0
  for _, r in ipairs(runs) do
    answered = answered + r.answered
    correct = correct + r.correct
  end
  local times = times_of(runs)
  return {
    label = label,
    stages = #runs,
    answered = answered,
    correct = correct,
    accuracy = pct(correct, answered),
    median_ms = median(times),
    median_kmh = kmh(median(times)),
    spread_ms = spread(times),
    spread_pct = spread_pct(times),
  }
end

-- The comparison that controls for what was asked.
--
-- Every binding answered correctly in BOTH windows, compared with itself. A
-- player who moved from Daily Driver to Endurance looks slower on the headline
-- and faster here, and here is the one that is true.
local function paired(early_runs, recent_runs)
  local function by_desc(runs)
    local acc = {}
    for _, r in ipairs(runs) do
      for _, a in ipairs(r.answers or {}) do
        if a.outcome == "correct" and real_ms(a.reaction_ms) then
          acc[a.description] = acc[a.description] or {}
          local t = acc[a.description]
          t[#t + 1] = a.reaction_ms
        end
      end
    end
    return acc
  end

  local early, recent = by_desc(early_runs), by_desc(recent_runs)
  local deltas, befores, improved, worsened, unchanged, best = {}, {}, 0, 0, 0, nil
  for desc, later in pairs(recent) do
    local before = early[desc]
    if before then
      local d = median(later) - median(before)
      deltas[#deltas + 1] = d
      befores[#befores + 1] = median(before)
      if d < 0 then improved = improved + 1
      elseif d > 0 then worsened = worsened + 1
      else unchanged = unchanged + 1 end
      -- The single most improved binding, for the screen to name. A number with
      -- an example attached is the difference between a statistic and a story.
      if best == nil or d < best.delta_ms then
        best = { description = desc, delta_ms = d,
                 before_ms = median(before), after_ms = median(later),
                 before_kmh = kmh(median(before)), after_kmh = kmh(median(later)) }
      end
    end
  end

  if #deltas < M.MIN_PAIRS then
    return { compared = #deltas, enough = false }
  end
  -- THE PAIR THE SCREEN SHOWS, built from the statistic the verdict uses.
  --
  -- "Then" is the typical binding before, "now" is that same binding moved by
  -- the median improvement. Reading the two windows' medians separately would
  -- have been the obvious thing and is the wrong thing: median-of-deltas and
  -- difference-of-medians are different numbers, and they can disagree in SIGN
  -- on a skewed set. That is a screen printing "FASTER" above a pair of speeds
  -- that got slower. Deriving one from the other makes that impossible.
  local delta = median(deltas)
  local before = median(befores)
  return {
    compared = #deltas,
    enough = true,
    improved = improved,
    worsened = worsened,
    unchanged = unchanged,
    median_delta_ms = delta,
    before_ms = before,
    after_ms = before + delta,
    before_kmh = kmh(before),
    after_kmh = kmh(before + delta),
    gain_kmh = kmh(before + delta) - kmh(before),
    best = (best and best.delta_ms < 0) and best or nil,
  }
end

-- Faster, slower, or the same, said in one word and only when the data earns it.
local function verdict_for(early, recent, pair)
  if not early.median_ms or not recent.median_ms then return "unknown" end
  local d = recent.median_ms - early.median_ms
  -- The paired number outranks the headline when it exists, because it is the
  -- one that compared like with like.
  if pair.enough then d = pair.median_delta_ms end
  if d <= -M.MEANINGFUL_MS then return "faster" end
  if d >= M.MEANINGFUL_MS then return "slower" end
  return "steady"
end

local function trend_for(runs)
  local counted = {}
  for _, r in ipairs(runs) do
    if r.counts then counted[#counted + 1] = r end
  end

  if #counted < M.MIN_TREND_STAGES then
    return {
      enough = false,
      stages = #counted,
      needed = M.MIN_TREND_STAGES,
    }
  end

  local w = math.min(M.WINDOW, math.floor(#counted / 2))
  local recent_runs, early_runs = {}, {}
  for i = 1, #counted do
    if i > #counted - w then recent_runs[#recent_runs + 1] = counted[i]
    else early_runs[#early_runs + 1] = counted[i] end
  end

  local early = window_stats(early_runs, ("your first %d stages"):format(#early_runs))
  local recent = window_stats(recent_runs, ("your last %d"):format(#recent_runs))
  local pair = paired(early_runs, recent_runs)

  return {
    enough = true,
    window = w,
    early = early,
    recent = recent,
    delta_ms = (early.median_ms and recent.median_ms)
      and (recent.median_ms - early.median_ms) or nil,
    delta_accuracy = (early.accuracy and recent.accuracy)
      and (recent.accuracy - early.accuracy) or nil,
    paired = pair,
    verdict = verdict_for(early, recent, pair),
    -- Consistency, reported separately because it moves first. Getting better
    -- usually looks like a narrowing spread before it looks like a lower median.
    tighter = (early.spread_pct and recent.spread_pct)
      and (recent.spread_pct < early.spread_pct) or false,
  }
end

-- --- what was interesting about the last stage ------------------------------

-- Facts about the most recent run, each one checkable against the record. No
-- encouragement that is not also true: "you are improving" printed after a bad
-- stage is how a screen loses the right to be believed.
local function notes_for(runs)
  local last = runs[#runs]
  if not last then return {} end
  local prior = {}
  for i = 1, #runs - 1 do prior[#prior + 1] = runs[i] end

  local out = {}
  local function say(text) out[#out + 1] = text end

  -- Bests and recoveries need to know what was true BEFORE this stage, so they
  -- are computed against prior runs only. Against all runs, every answer in the
  -- last stage would be its own best.
  local best_before, missed_before, seen_course = {}, {}, 0
  for _, r in ipairs(prior) do
    if r.course == last.course then seen_course = seen_course + 1 end
    for _, a in ipairs(r.answers or {}) do
      if a.outcome ~= "correct" then
        missed_before[a.description] = (missed_before[a.description] or 0) + 1
      elseif real_ms(a.reaction_ms) and not r.assisted then
        local cur = best_before[a.description]
        if cur == nil or a.reaction_ms < cur then best_before[a.description] = a.reaction_ms end
      end
    end
  end

  local bests, recovered, fastest, slowest = 0, {}, nil, nil
  for _, a in ipairs(last.answers or {}) do
    if a.outcome == "correct" and real_ms(a.reaction_ms) then
      if not last.assisted then
        local cur = best_before[a.description]
        if cur == nil or a.reaction_ms < cur then bests = bests + 1 end
      end
      if missed_before[a.description] then recovered[#recovered + 1] = a.description end
      if fastest == nil or a.reaction_ms < fastest.reaction_ms then fastest = a end
      if slowest == nil or a.reaction_ms > slowest.reaction_ms then slowest = a end
    end
  end

  -- A retirement is not a bad stage, and a panel that showed "1 answered" with
  -- no explanation would read as one. The header records the prompts PLANNED,
  -- which is the only place the walk-away is visible at all.
  if not last.completed then
    say(("retired part-way, %d of %d answered"):format(last.answered, last.planned or last.answered))
  end

  if last.clean then
    say("clean stage: nothing missed")
  elseif last.correct < last.answered then
    say(("%d off out of %d"):format(last.answered - last.correct, last.answered))
  end

  if fastest then
    say(("quickest: %s at %d km/h"):format(fastest.description, kmh(fastest.reaction_ms)))
  end

  if bests > 0 then
    say(("%d personal best%s set"):format(bests, bests == 1 and "" or "s"))
  elseif last.assisted then
    say("co-driver called, so no personal bests from this one")
  end

  if #recovered > 0 then
    say(("recalled after missing before: %s"):format(
      table.concat(recovered, ", ", 1, math.min(3, #recovered))))
  end

  -- How this stage sat against the player's own habit, which is the only
  -- baseline worth comparing a single stage to.
  -- Judged in milliseconds, said in km/h. The threshold is a noise floor and
  -- 100 ms is a constant one; the same gap is 7 km/h at a good pace and under
  -- 3 km/h at a slow one, so a km/h threshold would quietly hold a struggling
  -- player to a harder standard than a quick one.
  local prior_times = times_of(prior)
  local usual = median(prior_times)
  if usual and last.median_ms then
    local d = last.median_ms - usual
    if math.abs(d) >= M.MEANINGFUL_MS then
      say(("%d km/h %s than your usual %d km/h"):format(
        math.abs(kmh(last.median_ms) - kmh(usual)),
        d < 0 and "quicker" or "slower", kmh(usual)))
    else
      say(("right at your usual pace, %d km/h"):format(kmh(usual)))
    end
  end

  if slowest and fastest and slowest ~= fastest then
    say(("longest look: %s, %d km/h"):format(slowest.description, kmh(slowest.reaction_ms)))
  end

  if seen_course == 0 and last.course then
    say(("first time on %s"):format(last.label))
  end

  return out
end

-- --- per course -------------------------------------------------------------

local function courses_for(runs)
  local by, order = {}, {}
  for _, r in ipairs(runs) do
    local key = r.course or "all"
    if not by[key] then
      by[key] = { course = key, label = r.label, stages = 0, answered = 0,
                  correct = 0, times = {}, clean = 0, best_average_ms = nil }
      order[#order + 1] = key
    end
    local c = by[key]
    c.stages = c.stages + 1
    c.answered = c.answered + r.answered
    c.correct = c.correct + r.correct
    c.last_day = r.day or c.last_day
    if r.clean then c.clean = c.clean + 1 end
    for _, ms in ipairs(r.times) do c.times[#c.times + 1] = ms end
    if r.completed and r.median_ms then
      if c.best_average_ms == nil or r.median_ms < c.best_average_ms then
        c.best_average_ms = r.median_ms
      end
    end
  end

  local out = {}
  for _, key in ipairs(order) do
    local c = by[key]
    out[#out + 1] = {
      course = c.course, label = c.label, stages = c.stages,
      answered = c.answered, correct = c.correct,
      accuracy = pct(c.correct, c.answered),
      median_ms = median(c.times),
      median_kmh = kmh(median(c.times)),
      best_average_ms = c.best_average_ms,
      best_average_kmh = kmh(c.best_average_ms),
      clean = c.clean, last_day = c.last_day,
    }
  end
  -- Most-played first. The course someone actually drills is the one they want
  -- to read about, and alphabetical order buries it.
  table.sort(out, function(a, b)
    if a.stages ~= b.stages then return a.stages > b.stages end
    return tostring(a.label) < tostring(b.label)
  end)
  return out
end

-- --- the model --------------------------------------------------------------

function M.model(history_text)
  local parsed = core.parse_runs(history_text or "")
  local runs = {}
  for i, run in ipairs(parsed) do
    local r = read_run(run, i)
    r.answers = run.answers
    runs[#runs + 1] = r
  end

  if #runs == 0 then
    return {
      screen = "stats",
      empty = true,
      lifetime = { stages = 0, days = 0, answered = 0, correct = 0 },
      series = {}, courses = {}, records = {},
      trend = { enough = false, stages = 0, needed = M.MIN_TREND_STAGES },
    }
  end

  local answered, correct, clean, unassisted, days, day_order = 0, 0, 0, 0, {}, {}
  local all_times, fastest = {}, nil
  for _, r in ipairs(runs) do
    answered = answered + r.answered
    correct = correct + r.correct
    if r.clean then clean = clean + 1 end
    if not r.assisted then unassisted = unassisted + 1 end
    if r.day and not days[r.day] then
      days[r.day] = true
      day_order[#day_order + 1] = r.day
    end
    for _, ms in ipairs(r.times) do all_times[#all_times + 1] = ms end
    for _, a in ipairs(r.answers or {}) do
      if a.outcome == "correct" and real_ms(a.reaction_ms)
        and (fastest == nil or a.reaction_ms < fastest.reaction_ms) then
        fastest = a
      end
    end
  end

  local series = {}
  for _, r in ipairs(runs) do
    -- The chart draws only stages that count. A one-answer bail plotted as a
    -- point is a cliff in the line for something nobody played.
    if r.counts then
      series[#series + 1] = {
        index = #series + 1, day = r.day, course = r.course, label = r.label,
        accuracy = r.accuracy, median_ms = r.median_ms, median_kmh = r.median_kmh,
        answered = r.answered, clean = r.clean, assisted = r.assisted,
      }
    end
  end

  -- THE AXIS THE PACE LINE IS DRAWN AGAINST, decided here so the terminal
  -- sparkline and the overlay chart draw the same shape and the overlay's
  -- labels describe the line it actually drew.
  --
  -- Robust bounds, not the extremes. km/h is a RECIPROCAL of the measurement,
  -- so one exceptional stage sits three times as far from the pack as the pack
  -- is wide: scaled to the extremes, forty stages of real variation collapsed
  -- into the bottom two rows of the chart and the whole line went flat. Trimmed
  -- to the tenth and ninetieth percentiles the shape comes back, and the few
  -- points beyond the ends are clamped to them rather than dropped, so a record
  -- stage still reads as the top of the chart.
  local paces = {}
  for _, s in ipairs(series) do
    if s.median_kmh then paces[#paces + 1] = s.median_kmh end
  end
  local chart = {
    points = #paces,
    low_kmh = percentile(paces, 0.10),
    high_kmh = percentile(paces, 0.90),
  }
  -- A flat career has no axis to draw. Nil rather than a zero-width one, so a
  -- renderer has to decide what to do instead of dividing by nothing.
  if chart.low_kmh == chart.high_kmh then chart.low_kmh, chart.high_kmh = nil, nil end

  local records = {}
  if fastest then
    records[#records + 1] = {
      label = "top speed",
      value = ("%d km/h"):format(kmh(fastest.reaction_ms)),
      detail = fastest.description,
    }
  end
  local best_stage
  for _, r in ipairs(runs) do
    if r.counts and r.median_ms then
      if best_stage == nil or r.median_ms < best_stage.median_ms then best_stage = r end
    end
  end
  if best_stage then
    records[#records + 1] = {
      label = "quickest stage",
      value = ("%d km/h"):format(best_stage.median_kmh),
      detail = ("%s, %s"):format(best_stage.label, best_stage.day or "-"),
    }
  end
  local most_accurate
  for _, r in ipairs(runs) do
    if r.counts and r.accuracy then
      if most_accurate == nil or r.accuracy > most_accurate.accuracy
        or (r.accuracy == most_accurate.accuracy and r.answered > most_accurate.answered) then
        most_accurate = r
      end
    end
  end
  if most_accurate then
    records[#records + 1] = {
      label = "best stage",
      value = ("%d%%"):format(most_accurate.accuracy),
      detail = ("%d of %d, %s"):format(most_accurate.correct, most_accurate.answered,
        most_accurate.label),
    }
  end

  local last = runs[#runs]
  return {
    screen = "stats",
    empty = false,
    lifetime = {
      stages = #runs,
      days = #day_order,
      first_day = day_order[1],
      last_day = day_order[#day_order],
      answered = answered,
      correct = correct,
      accuracy = pct(correct, answered),
      median_ms = median(all_times),
      median_kmh = kmh(median(all_times)),
      clean = clean,
      unassisted = unassisted,
    },
    trend = trend_for(runs),
    series = series,
    chart = chart,
    courses = courses_for(runs),
    records = records,
    last = {
      day = last.day, course = last.course, label = last.label,
      difficulty = last.difficulty,
      answered = last.answered, correct = last.correct,
      accuracy = last.accuracy, median_ms = last.median_ms,
      median_kmh = last.median_kmh,
      planned = last.planned,
      completed = last.completed, clean = last.clean, assisted = last.assisted,
      notes = notes_for(runs),
    },
  }
end

return M

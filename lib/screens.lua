-- Every screen Omashift can draw, as a pure function of the published model.
--
--   screens.render(model) -> { line, line, ... }
--
-- WHY THIS EXISTS
--
-- The engine used to author each screen twice: once as text for the terminal
-- display, once as structured state for the Quickshell overlay. Ten render
-- blocks against nine publishes, hand-kept in sync, inside the file with the
-- worst history in this project. A screen that drifted only showed up if you
-- happened to be running that display.
--
-- Now there is one source. `publish` builds the model, this module turns it
-- into text, and the two cannot disagree because one is derived from the other.
--
-- THE RULE THAT KEEPS IT HONEST
--
-- This module may read NOTHING but the model it is handed. No `hl.*`, no engine
-- locals, no files, no clock. That is what lets it be tested by calling it, and
-- it is why `test/fixtures/screens/*.json` can be replayed straight through it.
-- If a screen needs a fact the model does not carry, add the fact to the model.
-- Do not reach around this boundary.
--
-- The one thing it may require is `core`, which is equally pure and already owns
-- shared presentation like the modifier wheels.

local core = require("core")

local M = {}

-- Gears are drawn from the model's own max, not a constant, so a stage that
-- reports a different gearbox draws the gearbox it reports.
local function gear_bar(gear, max_gear)
  local out = {}
  for i = 1, (max_gear or core.MAX_GEAR) do
    out[#out + 1] = (i <= (gear or 1)) and tostring(i) or "-"
  end
  return table.concat(out, " ")
end

local function titled(course)
  return "OMASHIFT" .. ((course and course ~= "") and ("  ·  " .. course) or "")
end

-- The in-play HUD block, shared by the prompt and the per-note result.
local function hud(lines, stage)
  lines[#lines + 1] = ("  stage  %d / %d"):format(stage.index or 0, stage.total or 0)
  lines[#lines + 1] = ("  gear   [ %s ]"):format(gear_bar(stage.gear, stage.max_gear))
  return lines
end

local R = {}

function R.loaded(m)
  return { "OMASHIFT", "", "  loaded. " .. tostring(m.bindings or 0) .. " bindings in the bank.", "" }
end

function R.ready(m)
  return {
    titled(m.course),
    "", "",
    "        ENTER starts  ·  C course  ·  D difficulty",
    "        T trophies  ·  S stats  ·  ^ v pace notes  ·  ESC leaves",
    "", "",
    ("  %s pace notes  ·  co-driver at %ss"):format(
      tostring(m.notes), tostring(m.codriver_s)),
    "",
    -- No silent default. A default that happens to be the right answer hides an
    -- engine that stopped sending the field, which fault injection caught doing
    -- exactly that: dropping launch_key from the model left this screen looking
    -- perfect. The formatter owns no facts.
    ("        %s"):format(m.launch_key or "(no launch key in the model)"),
    "",
    "  your keys still work until you do",
  }
end

function R.countdown(m)
  if m.lfg then
    return { "OMASHIFT", "", "", "        LFG!!!!", "", "" }
  end
  return {
    titled(m.stage and m.stage.course),
    "", "", ("        %d"):format(m.n or 0), "", "",
    "  get ready",
  }
end

function R.empty_course(m)
  -- Two ways to be empty, and they need different advice. A dynamic course has
  -- nothing to say yet; a curated one matched nothing in this keymap at all,
  -- which is not something playing more will fix.
  local why = m.dynamic
    and { "  play a few stages first. this course is built",
          "  from what you actually miss." }
    or  { "  nothing in your keymap matches this course.",
          "",
          "  courses match on what a binding is DESCRIBED as doing,",
          "  so a renamed or trimmed keymap can empty one out.",
          "  try another course, or `omashift --all`." }
  local lines = {
    "OMASHIFT  ·  " .. (m.label or m.course or ""),
    "", "",
    "  nothing to drill yet.",
    "",
  }
  for _, line in ipairs(why) do lines[#lines + 1] = line end
  return lines
end

function R.released(m)
  -- The watchdog fired, which means the game had stopped driving the screen
  -- while still holding the keyboard. Say so plainly: a player who finds this
  -- deserves to know their keys came back on their own and why.
  if m.reason == "watchdog" then
    return {
      "OMASHIFT", "", "",
      ("  the game stopped responding for %d seconds."):format(m.after_s or 0),
      "",
      "  your keybindings are back. run omashift again to restart.",
    }
  end
  if m.reason == "idle" then
    return {
      "OMASHIFT", "", "",
      ("  released after %d seconds idle."):format(m.after_s or 0),
      "",
      "  your keybindings are back. run omashift again to restart.",
    }
  end
  return { "OMASHIFT", "", "  retired.", "" }
end

function R.prompt(m)
  local stage = m.stage or {}
  local lines = { titled(stage.course), "" }
  hud(lines, stage)
  lines[#lines + 1] = ("  points %d%s"):format(stage.points or 0,
                                               stage.assisted and "   [CO-DRIVER]" or "")
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  PACE NOTE"
  lines[#lines + 1] = ("    >>  %s"):format((m.prompt or {}).description or "")
  if m.hint then
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("    co-driver:  %s"):format(m.hint.text or "")
  end
  -- A key that matches nothing in the keymap. While a stage runs the submap has
  -- replaced every binding, so such a key is not wrong, it is swallowed: the
  -- game got the press and had nothing to do with it. Saying so is the
  -- difference between a game that ignored you and a game that has hung.
  if m.unbound then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "    that key does nothing during a stage"
  end
  lines[#lines + 1] = ""
  for _, row in ipairs(core.wheels(m.held)) do lines[#lines + 1] = row end
  if m.quattro then lines[#lines + 1] = "        full quattro" end
  lines[#lines + 1] = ""
  -- From the model, never a literal. A hardcoded chord here could drift from the
  -- one the engine actually binds, and a hint naming a chord nothing is bound to
  -- is how a player gets trapped while reading the instructions. No silent
  -- default either, for the reason the ready screen learned the hard way.
  -- BOTH WAYS OUT, and the clock. From the model, never a literal: a hardcoded
  -- chord here could drift from the one the engine actually binds, and a hint
  -- naming a chord nothing is bound to is how a player gets trapped while
  -- reading the instructions. No silent default either, for the reason the
  -- ready screen learned the hard way.
  lines[#lines + 1] = ("  (%s to retire)"):format(m.retire_key or "no retire key in the model")
  if m.skip_key then
    lines[#lines + 1] = ("  (%s to skip this note)"):format(m.skip_key)
  end
  -- Only once it is close. A player who cannot answer the note in front of them
  -- needs to know that waiting works and how long it takes, because the honest
  -- reading of a screen that will not move on is that the machine has hung.
  if m.release_in_s then
    lines[#lines + 1] = ("  your keys come back on their own in %ds"):format(m.release_in_s)
  end
  return lines
end

function R.result(m)
  local stage, r = m.stage or {}, m.result or {}
  local head
  if r.outcome == "correct" then
    head = ("  %s  %d km/h  +%d"):format(
      r.praise or (r.tier or "ok"):upper(), r.speed_kmh or 0, r.points or 0)
  elseif r.outcome == "skipped" then
    -- Not an off, and it must not read like one. You did not get this wrong,
    -- you declined it, and the game is not going to hold it against you.
    head = r.retired
      and "  SKIPPED: that is twice, so it leaves the rotation"
      or  "  SKIPPED: this one will not come back"
  else
    head = "  OFF, into the scenery"
  end

  local lines = { "OMASHIFT", "" }
  hud(lines, stage)
  lines[#lines + 1] = ("  points %d"):format(stage.points or 0)
  lines[#lines + 1] = ""
  lines[#lines + 1] = head

  -- Signed on purpose. "+340" against "-340" is the whole reading; an unsigned
  -- number would make you work out which side of the ghost you are on.
  if r.ghost_gap_s then
    lines[#lines + 1] = r.best
      and ("    NEW BEST, %+.2fs on your ghost"):format(r.ghost_gap_s)
      or  ("    ghost %d km/h   %+.2fs"):format(r.ghost_kmh or 0, r.ghost_gap_s)
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = ("    expected: %s   (%s)"):format(r.expected or "", r.description or "")
  if r.alts and #r.alts > 0 then
    lines[#lines + 1] = ("    also works: %s"):format(table.concat(r.alts, ", "))
  end
  if r.outcome == "off" then
    lines[#lines + 1] = ("    you pressed: %s%s"):format(
      r.pressed or "",
      r.pressed_was and ("  · " .. r.pressed_was) or "  · not a binding")
  end
  return lines
end

function R.results(m)
  local s = m.summary or {}
  local lines = {
    "OMASHIFT · STAGE COMPLETE", "",
    -- Two columns padded to a fixed width. The left values vary in length,
    -- "7 / 8" against "10 / 17  (7 re-asked)", so anything less than an explicit
    -- field makes the right column wander down the page.
    ("  %-34s %s"):format(
      ("correct   %d / %d%s"):format(s.correct or 0, s.prompts or 0,
        (s.requeues or 0) > 0 and ("  (%d re-asked)"):format(s.requeues) or ""),
      ("points     %d"):format(s.points or 0)),
    ("  %-34s %s"):format(
      ("offs      %d"):format(s.offs or 0),
      ("clean      %s"):format(
        (s.clean and not s.assisted) and "yes, Direct Drive"
        or (s.clean and "yes (co-driver, no PB)" or "no"))),
    ("  %-34s %s"):format(
      ("avg speed %s"):format(s.average_kmh and ("%d km/h"):format(s.average_kmh) or "n/a"),
      ("top speed  %s"):format(s.top_kmh and ("%d km/h"):format(s.top_kmh) or "n/a")),
    s.ghost_gap_s and ("  vs ghost  %+.2fs over %d note%s   (%d beaten)"):format(
      s.ghost_gap_s, s.ghost_notes or 0, (s.ghost_notes == 1) and "" or "s", s.ghost_beat or 0)
      or "  vs ghost  none yet. play a stage without the co-driver",
  }

  if (s.away or 0) > 0 then
    lines[#lines + 1] = ("  away      %d note%s excluded from the averages"):format(
      s.away, s.away == 1 and "" or "s")
  end

  for _, t in ipairs(m.trophies or {}) do
    lines[#lines + 1] = ("  TROPHY    %s%s"):format(
      t.phrase, t.tier and ("  (" .. t.tier .. ")") or "")
  end

  -- The ladder is suppressed when nothing was graded. The model does not carry
  -- a "graded" count, and it does not need to: graded IS the sum of the tier
  -- counts, so the fact is already in the data.
  local graded = 0
  for _, t in ipairs(m.ladder or {}) do graded = graded + (t.count or 0) end

  local left, right = {}, {}
  if graded > 0 then
    left[#left + 1] = "LADDER"
    for _, t in ipairs(m.ladder or {}) do
      left[#left + 1] = ("  %-13s %2d %3d%% %s"):format(
        t.name, t.count or 0, math.floor((t.share or 0) * 100 + 0.5),
        string.rep("#", math.floor((t.share or 0) * 10 + 0.5)))
    end
  end
  right[#right + 1] = "SPLITS"
  for _, sp in ipairs(m.splits or {}) do
    right[#right + 1] = ("  %-11s %s  %d/%d%s"):format(
      sp.name,
      sp.speed_kmh and ("%3d km/h"):format(sp.speed_kmh) or "   --  ",
      sp.correct or 0, sp.asked or 0,
      (sp.offs or 0) > 0 and ("  %d off"):format(sp.offs) or "")
  end

  lines[#lines + 1] = ""
  for i = 1, math.max(#left, #right) do
    -- Trimmed: the columns are different lengths, so padding the left one on a
    -- row with nothing to its right leaves a tail of blanks that shows up as
    -- stray selection and trailing whitespace when anyone copies the screen.
    lines[#lines + 1] = (("  %-36s %s"):format(left[i] or "", right[i] or ""):gsub("%s+$", ""))
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  NOTES"
  for _, r in ipairs(m.notes or {}) do
    local mark = (r.outcome == "correct") and " ok" or "OFF"
    local v = ("%3d km/h"):format(r.speed_kmh or 0)
    -- The wrong press is the teaching signal, so it stays on the same line as
    -- the miss. Only a miss pads the description; a correct note would otherwise
    -- carry 30 columns of trailing blanks it has no use for.
    if r.outcome == "off" then
      lines[#lines + 1] = ("    %s %s  %-32s you pressed %s%s"):format(
        mark, v, r.description, r.pressed or "",
        r.pressed_was and ("  · " .. r.pressed_was) or "")
    else
      lines[#lines + 1] = ("    %s %s  %s"):format(mark, v, r.description)
    end
  end
  lines[#lines + 1] = ""
  -- The three things this screen accepts. The overlay holds the keyboard while
  -- it is up, so these are the only keys that do anything at all, and going
  -- again is the ordinary reason anyone is still looking at it.
  lines[#lines + 1] = "  ENTER goes again  ·  ESC back to the menu  ·  P saves a picture"
  return lines
end

-- THE CABINET: what you have won, and what there is to win.
--
-- Shows LOCKED and unearned trophies on purpose. A new player opening a mostly
-- empty cabinet should see what the game will eventually teach them, so the
-- empty state is the roadmap. That matters most to exactly the audience this is
-- built for.
--
-- `why` is not part of the model: it is a request for MORE of the same model,
-- so it rides on the model like any other field.
function R.cabinet(m)
  local lines = {}
  for _, sec in ipairs(m.sections or {}) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = sec.label
    for _, r in ipairs(sec.rows or {}) do
      local mark, detail
      if r.tiered then
        local t = r.tiered
        mark = t.tier and ("[" .. t.tier .. "]") or "[      ]"
        detail = t.maxed and ("%d, maxed"):format(t.count)
          or ("%d/%d to %s"):format(t.count, t.next_at, t.next_tier)
      elseif r.per_course then
        mark = (r.held > 0) and ("[%d/%d]"):format(r.held, r.of) or "[     ]"
        detail = r.complete and "every course" or "one per course"
      else
        mark = r.day and "[ won ]" or "[     ]"
        detail = r.day and ("earned " .. r.day) or (r.locked or "not yet")
      end
      lines[#lines + 1] = ("  %-8s %-22s %-28s%s"):format(
        mark, r.phrase, detail, r.locked and "  ·  LOCKED" or "")
      -- WHAT IT MEANS TO HAVE WON IT, always. A cabinet full of phrases nobody
      -- can decode is a wall of nicknames: "Cache Hit" and "Sharp Knives" say
      -- nothing about what you did. The note is the earn condition in a few
      -- words, and it is not the attribution -- `source` is, and that stays
      -- behind --why, because a permanent display naming its references reads as
      -- a patron endorsement.
      if (r.note or "") ~= "" then
        lines[#lines + 1] = ("           %s"):format(r.note)
      end
      if m.why then
        lines[#lines + 1] = ("           source: %s"):format(r.source or "-")
      end
    end
  end

  local s = m.summary or {}
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("  %d of %d earned."):format(s.won or 0, s.total or 0)
  if (s.days or 0) > 0 then
    lines[#lines + 1] = ("  played on %d day%s, most recently %s."):format(
      s.days, s.days == 1 and "" or "s", tostring(s.last_day))
  end
  if not m.why then
    lines[#lines + 1] = "  omashift-cabinet --why  explains where the names come from."
  end
  return lines
end

-- An unknown screen must be LOUD. Returning an empty table would render a blank
-- display, which is indistinguishable from a hung game and is the worst possible
-- way to find out a screen name was mistyped.
-- --- the Logbook -----------------------------------------------------------

-- Eight steps of block, so a forty-stage series fits on one line and still has
-- shape. Drawn from km/h, which is what the rest of the screen reports, so
-- taller is quicker without anything having to be inverted or explained.
local BLOCKS = { "\226\150\129", "\226\150\130", "\226\150\131", "\226\150\132",
                 "\226\150\133", "\226\150\134", "\226\150\135", "\226\150\136" }

-- `lo`/`hi` fix the axis when the caller owns it. Passing them is how the pace
-- line here and the pace line on the overlay end up being the same drawing.
local function sparkline(values, lo, hi)
  if lo == nil or hi == nil then
    lo, hi = nil, nil
    for _, v in ipairs(values) do
      if v then
        if lo == nil or v < lo then lo = v end
        if hi == nil or v > hi then hi = v end
      end
    end
  end
  if lo == nil then return "" end
  local out = {}
  for _, v in ipairs(values) do
    if v == nil then
      out[#out + 1] = " "
    elseif hi == lo then
      -- A flat series is flat. Scaling it to full height would draw a mountain
      -- range out of forty identical numbers.
      out[#out + 1] = BLOCKS[4]
    else
      -- Clamped, because a fixed axis can be narrower than the data.
      local t = math.max(0, math.min(1, (v - lo) / (hi - lo)))
      out[#out + 1] = BLOCKS[math.max(1, math.min(#BLOCKS, math.floor(t * #BLOCKS) + 1))]
    end
  end
  return table.concat(out)
end

local VERDICT = {
  faster  = "FASTER than when you started.",
  slower  = "SLOWER than when you started.",
  steady  = "HOLDING STEADY.",
  unknown = "not enough clean answers to say.",
}

function R.stats(m)
  local lines = { "OMASHIFT  \194\183  THE LOGBOOK", "" }
  local function add(fmt, ...)
    lines[#lines + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
  end

  if m.empty then
    add("  nothing recorded yet. Play a stage and this fills in.")
    add("")
    return lines
  end

  local t = m.trend or {}
  add("  ARE YOU GETTING BETTER?")
  add("")
  if not t.enough then
    -- The honest answer to "not yet". A verdict drawn from three stages would
    -- be noise wearing a conclusion's clothes.
    add("    %d of %d stages recorded. Ask again after %d more.",
      t.stages or 0, t.needed or 0, math.max(0, (t.needed or 0) - (t.stages or 0)))
  else
    add("    %s", VERDICT[t.verdict] or VERDICT.unknown)
    local p = t.paired or {}
    if p.enough then
      -- The number that controls for what was asked, said first, because it is
      -- the one that survives moving to a harder course.
      add("    %d of %d bindings seen in both windows improved: %d km/h to %d km/h.",
        p.improved, p.compared, p.before_kmh, p.after_kmh)
      if p.best then
        add("    biggest gain: %s, %d km/h to %d km/h.",
          p.best.description, p.best.before_kmh, p.best.after_kmh)
      end
    else
      add("    (%d bindings seen in both windows, too few to compare fairly)",
        p.compared or 0)
    end
    add("")
    add("    %-22s %6s %9s %10s %10s", "window", "stages", "accuracy", "typical", "spread")
    for _, w in ipairs({ t.early, t.recent }) do
      add("    %-22s %6d %8s%% %5s km/h %7s%%", w.label, w.stages,
        tostring(w.accuracy or "-"), tostring(w.median_kmh or "-"),
        tostring(w.spread_pct or "-"))
    end
    if t.tighter then
      add("    Your answers are clustering tighter, which usually comes first.")
    end
  end

  local speeds, accs = {}, {}
  for _, s in ipairs(m.series or {}) do
    speeds[#speeds + 1] = s.median_kmh
    accs[#accs + 1] = s.accuracy
  end
  if #speeds > 1 then
    add("")
    add("  EVERY STAGE, IN ORDER  (%d of them)", #speeds)
    local c = m.chart or {}
    add("    pace      %s", sparkline(speeds, c.low_kmh, c.high_kmh))
    add("    accuracy  %s", sparkline(accs))
  end

  local L = m.lifetime or {}
  add("")
  add("  ALL TIME")
  add("    %d stages over %d day%s, %s to %s.", L.stages or 0, L.days or 0,
    (L.days == 1) and "" or "s", tostring(L.first_day), tostring(L.last_day))
  add("    %d of %d answers correct (%s%%), typical %s km/h.",
    L.correct or 0, L.answered or 0, tostring(L.accuracy or "-"), tostring(L.median_kmh or "-"))
  add("    %d clean stages, %d run without the co-driver.", L.clean or 0, L.unassisted or 0)

  if #(m.courses or {}) > 0 then
    add("")
    add("  BY COURSE")
    add("    %-20s %6s %9s %10s %7s", "course", "stages", "accuracy", "typical", "clean")
    for _, c in ipairs(m.courses) do
      add("    %-20s %6d %8s%% %5s km/h %7d", c.label, c.stages,
        tostring(c.accuracy or "-"), tostring(c.median_kmh or "-"), c.clean or 0)
    end
  end

  local last = m.last
  if last then
    add("")
    add("  YOUR LAST STAGE  \194\183  %s%s, %s", tostring(last.label),
      last.difficulty and (", " .. last.difficulty) or "", tostring(last.day))
    for _, n in ipairs(last.notes or {}) do
      add("    \194\183 %s", n)
    end
  end

  if #(m.records or {}) > 0 then
    add("")
    add("  RECORDS")
    for _, r in ipairs(m.records) do
      add("    %-18s %-10s %s", r.label, r.value, r.detail)
    end
  end

  add("")
  return lines
end

function M.render(model)
  if type(model) ~= "table" or model.screen == nil then
    return { "OMASHIFT", "", "  no screen to draw.", "" }
  end
  local fn = R[model.screen]
  if not fn then
    return {
      "OMASHIFT", "", ("  unknown screen: %s"):format(tostring(model.screen)),
      "", "  this is a bug in the engine, not in your keymap.",
    }
  end
  return fn(model)
end

function M.text(model)
  return table.concat(M.render(model), "\n") .. "\n"
end

-- Every screen this module knows how to draw, so a test can assert that the
-- engine publishes nothing it cannot render and that nothing here is dead.
function M.names()
  local out = {}
  for name in pairs(R) do out[#out + 1] = name end
  table.sort(out)
  return out
end

return M

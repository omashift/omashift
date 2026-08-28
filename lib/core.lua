-- Omashift core: all game logic, and nothing that touches Hyprland.
--
-- This module deliberately has NO dependency on `hl.*`, so it runs under plain
-- `lua` and can be unit-tested without a compositor. Everything that needs the
-- compositor lives in engine.lua, which is a thin wiring layer over this.
--
-- Determinism is a design requirement, not a convenience: the caller supplies
-- the seed and every timestamp, so a test can replay an entire stage exactly.

local M = {}

-- ---------------------------------------------------------------------------
-- Scoring
-- ---------------------------------------------------------------------------

-- Reaction-time tiers, fastest first. Thresholds are milliseconds from the
-- moment the pace note is shown to the moment the combo lands.
--
-- CALIBRATED AGAINST REAL PLAY, not guessed. The original boundaries
-- (200/300/600/1200) were recognition-speed numbers, and this game measures
-- RECALL: read a pace note, retrieve the combo, execute it. That is a 1-4 s
-- operation. Across the first 76 timed answers the fastest was 780 ms and
-- nothing landed above `steady` -- so the gearbox, which upshifts only on
-- sub-300 ms answers, had never once fired. A core mechanic that cannot
-- activate is not difficulty, it is dead weight.
--
-- These boundaries put that 780 ms personal best in `on-rails` and spread the
-- rest the way the play actually falls: ~10% clean, ~22% steady, ~66% slow.
-- `zero-latency` stays deliberately unreached -- 180 ms faster than the best
-- run so far, which is a stretch goal rather than a fiction.
M.TIERS = {
  { max = 600,   name = "zero-latency", points = 100, praise = "Zero Latency" },
  { max = 900,   name = "on-rails",     points = 75,  praise = "You're On Rails" },
  { max = 1250,  name = "clean",        points = 50,  praise = nil },
  { max = 1750,  name = "steady",       points = 25,  praise = nil },
  { max = math.huge, name = "slow",     points = 10,  praise = nil },
}

-- Reaction time as SPEED, which is what a racing game should be showing.
--
-- Not an arbitrary re-scaling: treat each pace note as a corner you are timed
-- through, and a fixed distance over your time IS a speed. So this is `d / t`,
-- honestly, which also happens to put the resolution exactly where real play
-- lives. 1/t spreads 600-3000 ms across 250 down to 50 km/h, where a linear
-- map would bunch everything near the top and waste the interesting range.
--
-- 250 km/h at the top of `zero-latency` because that is roughly what an Audi
-- Sport quattro S1 E2 actually did, and the game is Group B all the way down.
-- Absolute, NOT scaled by difficulty: your speed is your speed, and the tier is
-- the judgement of it. Making easy mode report faster numbers would be lying.
M.SPEED = { top_kmh = 250, at_ms = 600 }

-- 0 means stopped: a wrong answer put you in the scenery, and an away-length
-- pause means you were not driving at all.
function M.speed_kmh(reaction_ms)
  local ms = tonumber(reaction_ms)
  if not ms or ms <= 0 or ms >= M.AWAY_MS then return 0 end
  local kmh = (M.SPEED.top_kmh * M.SPEED.at_ms) / ms
  return math.min(M.SPEED.top_kmh, math.floor(kmh + 0.5))
end

M.MAX_GEAR = 4
M.MIN_GEAR = 1

-- Momentum starts at this tier. "steady or better" is, in practice, "not slow",
-- which is what a gearbox should track. Chaining fast answers was the right
-- idea, but pinned to the top two tiers it demanded speed the game never sees:
-- 1 answer in 76 qualified, so the multiplier sat at x1 forever.
--
-- One tier NAME rather than a per-mode number, because the boundaries already
-- scale with difficulty, so the same rule yields roughly 64% of answers
-- qualifying on easy, 34% on medium and 9% on hard, with nothing hand-tuned.
M.UPSHIFT_TIER = "steady"

-- Rank of a tier, 1 = fastest. Comparing names directly would make the ordering
-- implicit in a string, which is how a reordered table becomes a silent bug.
function M.tier_rank(name)
  for i, tier in ipairs(M.TIERS) do
    if tier.name == name then return i end
  end
  return #M.TIERS
end

-- Difficulty presets. One knob moves the tier ladder (see tier_for) and one
-- moves how soon the co-driver speaks, because those are the two things that
-- decide how hard a stage feels: how fast you must be to score, and how long
-- you are left alone to remember.
--
-- THIS TABLE IS THE ONLY PLACE THE NUMBERS LIVE. The launcher passes the mode's
-- NAME through to the engine and resolves nothing itself -- a second copy in
-- bash would have drifted the first time either side was tuned.
--
-- Medium is not a midpoint chosen for symmetry: it is the calibration above,
-- plus the co-driver timing already arrived at by playing.
--
-- The idle release is deliberately NOT here. It is a safety feature -- it stops
-- a walked-away player's keyboard being held hostage -- and making it part of a
-- challenge setting would mean "hard mode" could strand you.
M.DIFFICULTY = {
  easy   = { label = "Easy",   tier_scale = 1.4, hint_mods = 2500, hint_full = 5000 },
  medium = { label = "Medium", tier_scale = 1.0, hint_mods = 4000, hint_full = 8000 },
  hard   = { label = "Hard",   tier_scale = 0.7, hint_mods = 6000, hint_full = 12000 },
}
M.DEFAULT_DIFFICULTY = "medium"

-- Unknown names fall back to the default rather than erroring: a typo in a
-- config file should cost you the mode you wanted, not the session.
function M.difficulty(name)
  return M.DIFFICULTY[tostring(name or "")] or M.DIFFICULTY[M.DEFAULT_DIFFICULTY]
end


-- Reaction time in ms -> tier table. Negative or nil times are treated as slow
-- rather than erroring: a clock hiccup should not crash a stage mid-run.
--
-- `scale` is the difficulty knob: every threshold is multiplied by it, so one
-- number moves the whole ladder and the SHAPE calibrated above is preserved.
-- Below 1 the tiers tighten (harder), above 1 they loosen. The last tier is
-- math.huge, which stays huge under any scale, so there is always a fallthrough.
function M.tier_for(reaction_ms, scale)
  scale = tonumber(scale) or 1
  if scale <= 0 then scale = 1 end
  if type(reaction_ms) ~= "number" or reaction_ms < 0 then
    return M.TIERS[#M.TIERS]
  end
  for _, tier in ipairs(M.TIERS) do
    if reaction_ms <= tier.max * scale then
      return tier
    end
  end
  return M.TIERS[#M.TIERS]
end

-- Gear multiplies points. Four gears, because quattro.
function M.multiplier(gear)
  return gear
end

-- Chaining fast answers upshifts; an off downshifts. Gears clamp at 1 and 4.
function M.upshift(gear)
  return math.min(M.MAX_GEAR, (gear or M.MIN_GEAR) + 1)
end

function M.downshift(gear)
  return math.max(M.MIN_GEAR, (gear or M.MIN_GEAR) - 1)
end

-- ---------------------------------------------------------------------------
-- Courses
-- ---------------------------------------------------------------------------

-- Courses are tiered by HOW OFTEN YOU'D DO THE THING, never by modifier depth.
-- Grouping by modmask leaks the answer: the player pre-loads the modifiers and
-- only reaction-times the key, which trains half the skill.
--
-- Matched on description rather than combo, precisely so the tier survives a
-- user remapping their keys.
M.COURSES = {
  ["daily-driver"] = {
    -- the road you drive every day.
    scene = { theme = "tokyo-night", file = "0-winding-road.jpg", scrim = 0.52 },
    label = "Daily Driver",
    note  = "the dozen things you do constantly",
    patterns = {
      "^Terminal$", "^Browser$", "^Close window$", "^Full screen$",
      "^Omarchy menu$", "^System menu$", "^Toggle window floating",
      "^Focus on %a+ window$",
      "^Switch to workspace [1-4]$", "^Next workspace$", "^Previous workspace$",
      "^Universal copy$", "^Universal paste$", "^Universal cut$",
      "^File manager$", "^Keybindings$",
    },
  },
  -- The things you OPEN, as opposed to the things you do to a window once it is
  -- open. Every other course is about operating the desktop; this one is about
  -- getting into the program you actually wanted.
  --
  -- It is the highest-frequency course in the set for most people, and the one
  -- where a mouse habit costs the most: reaching for a launcher, typing a name
  -- and waiting for a match is several seconds against a chord.
  --
  -- Deliberately excludes one-shot actions that happen to live near the app
  -- launchers in the menu -- setting a reminder, showing the time, copying a URL
  -- out of a web app. Those are things you DO, not things you open, and mixing
  -- them in would make the course mean nothing in particular.
  ["apps"] = {
    -- the city you move around in.
    scene = { theme = "nord", file = "1-city-view.png", scrim = 0.50 },
    label = "Apps",
    note  = "opening the things you actually use",
    -- System panels are NOT here, though they launch the same way. Bluetooth,
    -- Network, Display and Activity are settings surfaces rather than programs
    -- you work in, and they are used rarely, so they live in Endurance with the
    -- other far corners. An app you open twenty times a day and a panel you open
    -- twice a month do not belong in the same drill.
    patterns = {
      "^Terminal$", "^Tmux$", "^Editor$", "^Browser", "^File manager",
      "^Email$", "^New email$", "^Calendar$", "^Calculator$", "^Passwords$",
      "^Music$", "^Music TUI$", "^Obsidian$", "^Omawrite$", "^Omashift$",
      "^Signal$", "^WhatsApp$", "^Google %a+$", "^ChatGPT$", "^Grok$",
      "^X$", "^X Post$", "^YouTube$", "^Docker$", "^Spin %a+$",
    },
  },
  -- Controlling the machine itself, as opposed to the windows on it or the
  -- programs in them. Menus, power, audio, the lock, notifications, the bits of
  -- chrome you toggle.
  --
  -- Added last because it was the biggest hole: 53 bindings, a quarter of the
  -- keymap, belonged to no course at all and were reachable only with `--all`.
  -- These are also the least discoverable things on the machine, which makes
  -- them exactly what a trainer is for. Nobody stumbles onto the hardware menu.
  ["system"] = {
    label = "System",
    note  = "the machine itself: menus, power, audio, notifications",
    -- A cyan wireframe on black: the machine's own internals, which is what this
    -- course is about. The only cool-temperature backdrop in an otherwise warm
    -- set, deliberately, because it is the odd one out. It replaced vantablack's
    -- layered dark, which at any scrim read as a black rectangle.
    scene = { theme = "hackerman", file = "2-geometric.jpg", scrim = 0.42 },
    patterns = {
      "^Apps menu$", "^Hardware menu$", "^Capture menu$", "^Theme menu$",
      "^Toggle menu$", "^Share$", "^Emojis$",
      "^Audio$", "^Power$", "^Lock system$", "^Toggle dictation$",
      "^Background switcher$", "^Toggle top bar$", "^Toggle weather$",
      "^Toggle silencing notifications$", "^Dismiss all notifications$",
      "^Invoke last notification$", "^Open notification history$",
      "^Zoom in$", "^Reset zoom$",
    },
  },
  -- THE LEFTOVERS, and they are a course rather than an exclusion list.
  --
  -- Every one of these was going to be written off: the nine numbered bar
  -- panels, the readouts you glance at, the contextual web-app actions, the two
  -- cheat sheets, the personal tools with no natural home. Twenty-three bindings
  -- that fit nowhere and were about to be documented as deliberately untaught.
  --
  -- They are still on your keyboard. A trainer that quietly skips a quarter of
  -- the odd-shaped keys is teaching you the tidy half of your own machine, and
  -- the odd-shaped ones are exactly the ones nobody remembers.
  --
  -- Named for the rally service park: the fenced-off area between stages where
  -- the crew works, full of the specific tools that matter twice a weekend and
  -- are useless the rest of the time. It gets the best backdrop in the set on
  -- purpose, because a course of misfits should not look like a bin.
  ["service-park"] = {
    label = "Service Park",
    note  = "the odd-shaped keys nobody remembers",
    scene = { theme = "ristretto", file = "0-launch.png", scrim = 0.62 },
    patterns = {
      "^Bar panel %d$",
      "^Show time$", "^Show battery remaining$",
      "^Set reminder$", "^Show reminders$", "^Clear reminders$",
      "^Copy URL from Web App$", "^Download Video from Web App$",
      "^Make webcam overlay %a+$",
      "^Herdr keybindings$", "^Tmux keybindings$",
      "^Agent$", "^Herdr$", "^Transcode$",
    },
  },
  ["the-commute"] = {
    -- Brueghel's carts on a path. Bright and busy, so it needs the heaviest scrim in the set.
    scene = { theme = "gruvbox", file = "4-idyllic-procession.jpg", scrim = 0.64 },
    label = "The Commute",
    note  = "several times a day",
    patterns = {
      "^Move window to workspace [1-9]$", "^Swap window",
      "^Email$", "^Calendar$", "^ChatGPT$", "^Docker$", "^Signal$",
      "^Toggle scratchpad$", "^Move window to scratchpad$", "^Former workspace$",
      "^Dismiss last notification$", "^Screenshot$",
      "^Switch to workspace [5-9]$", "^Switch to workspace 10$",
    },
  },
  -- Weekly things. This is where the window manager stops being a place to put
  -- terminals and starts being a tool: grouping, splitting, sizing, monitors.
  ["track-day"] = {
    -- the game's own motif, and it was already on the machine.
    scene = { theme = "tokyo-night", file = "1-quattro.jpg", scrim = 0.58 },
    label = "Track Day",
    note  = "weekly: shaping windows rather than just opening them",
    patterns = {
      "^Toggle window grouping$", "^Toggle window split$", "^Toggle window transparency$",
      "^Toggle window gaps$", "^Toggle workspace layout$", "^Toggle single%-window",
      "^Focus on %a+ monitor$", "^Move workspace to %a+ monitor$",
      "^Clipboard manager$", "^Color picker$", "^Pseudo window$",
      "^Expand window %a+$", "^Shrink window %a+$",
      -- The precise variants, which were orphaned: this course already owns
      -- sizing, and "a little" versus "a lot" is the same skill at finer grain.
      "^Expand window %a+ a %a+$", "^Shrink window %a+ a %a+$",
      "^Save window width$", "^Restore window width$", "^Full width$", "^Tiled full screen$",
      "^Move window to group on", "^Move active window out of group$",
      "^%a+ window in group$", "^Switch to group window %d$", "^Move grouped window focus",
    },
  },
  -- Rare things, and the ones a switcher will not discover on their own: precise
  -- media and brightness steps, the far workspaces, screen recording. Named for
  -- Le Mans, so it is also the endgame the trophy case points at.
  ["endurance"] = {
    -- a long night voyage. Dark already, so it barely needs dimming.
    scene = { theme = "matte-black", file = "0-ship-at-sea.jpg", scrim = 0.52 },
    label = "Endurance",
    note  = "rare: the far corners of the keymap",
    patterns = {
      "^Volume %a+ precise$", "^Brightness %a+ precise$", "^Brightness m%a+imum$",
      "^Switch media source$", "^Switch audio output$", "^%a+ track$",
      "^Monitor scaling %a+$", "^Close all windows$",
      -- The system panels. They launch like apps but are not apps: you do not
      -- work in them, and you reach for them rarely, which is this course.
      "^Bluetooth$", "^Network$", "^Display$", "^Activity$",
      "^Switch to workspace [7-9]$", "^Switch to workspace 10$",
      "^Move window to workspace [7-9]$", "^Move window to workspace 10$",
      "^Move window silently to workspace",
      "^Pop window out", "^Screenrecording$", "^Extract text %(OCR%)",
      "^Toggle laptop display", "^Toggle locking on idle$", "^Toggle nightlight$",
    },
  },
  -- No patterns: the entry set is mined from history.jsonl at launch. Listed
  -- here so it appears in course_names() and the CLI usage line alongside the
  -- hand-curated tiers -- which is also the point of it. The curated tiers are
  -- guesses about what matters; this one is the correction mechanism, built from
  -- what the player actually got wrong.
  ["blind-spots"] = {
    -- what you cannot see.
    scene = { theme = "nord", file = "0-black-moon.jpg", scrim = 0.55 },
    label   = "Blind Spots",
    note    = "what you actually keep missing",
    dynamic = true,
  },
}

-- What counts as a blind spot. THIS is the definition of record -- the report in
-- bin/omashift-stats is a human view of the same file and deliberately shows
-- more than a course takes.
-- The backdrop when no course is chosen (`--all`), and the fallback for a course
-- that names a theme this machine does not have installed.
--
-- Scrim rather than opacity: the image is atmosphere, the words are the game.
-- Every screen that has ever been unreadable in this project was unreadable
-- because something pretty was competing with the text, so each scene carries
-- how hard to dim it rather than trusting one number to suit a Brueghel and a
-- black moon equally.
M.DEFAULT_SCENE = { theme = "tokyo-night", file = "0-winding-road.jpg", scrim = 0.52 }

M.BLIND_SPOT = {
  min_misses = 2,     -- one miss is noise; two across sessions is a pattern
  slow_ms    = 3000,  -- right but this slow is a weakness one notch down
  max_ms     = 30000, -- above this the player was away, not thinking
}

-- Bindings that deliberately belong to no course.
--
-- EMPTY, and that is the point. It exists because 53 bindings, a quarter of the
-- keymap, once drifted out of every course and were reachable only with `--all`.
-- The mechanism stays so the coverage test has something to check against, and
-- so that excluding a binding in future is a decision written down here with a
-- reason rather than an accident nobody notices.
--
-- The twenty-three that lived here are now the Service Park course. They were
-- odd-shaped rather than unteachable, and odd-shaped is what a trainer is for.
M.UNCOURSED = {}

-- Whether a binding is deliberately outside every course.
--
-- Through M, not the local: `safe_match` is declared further down this file, so
-- a bare reference here compiles as a global lookup and is nil at call time.
function M.is_uncoursed(description)
  for _, pat in ipairs(M.UNCOURSED) do
    if M.safe_match(description or "", pat) then return true end
  end
  return false
end

-- The scene for a course, falling back to the default for `--all`, an unknown
-- name, or a course that never named one.
function M.scene_for(course)
  local c = course and M.COURSES[course]
  return (c and c.scene) or M.DEFAULT_SCENE
end

-- Every combo currently bound to each action, alternates included. Both readers
-- of the history take this, so "still bound" means the same thing to each.
function M.live_combos(inventory)
  local out = {}
  for _, e in ipairs(inventory or {}) do
    out[e.description] = out[e.description] or {}
    out[e.description][e.combo] = true
  end
  return out
end

-- Evidence recorded against a combo the action no longer has. Shared by Blind
-- Spots and the ghost so the two cannot disagree about what still counts.
local function stale_evidence(live, a)
  return live ~= nil and live[a.description] ~= nil
    and a.combo ~= nil and not live[a.description][a.combo]
end

-- Your ghost: the fastest you have ever answered each action.
--
-- ONLY FROM UNASSISTED STAGES. A stage where the co-driver called anything
-- still trains and still scores, but it cannot set a personal best -- a ghost
-- built from hinted answers is a time you never actually drove, and chasing it
-- would be chasing the hint.
--
-- Away-outliers are excluded on the same threshold as everywhere else, and a
-- best set on a combo you have since remapped is dropped: it is a fact about a
-- keystroke you no longer have.
function M.personal_bests(history_text, opts)
  opts = opts or {}
  local max_ms = opts.max_ms or M.BLIND_SPOT.max_ms
  local live = opts.combos
  local best = {}
  for _, a in ipairs(M.parse_history(history_text)) do
    if a.outcome == "correct" and not a.assisted
      and a.reaction_ms and a.reaction_ms > 0 and a.reaction_ms < max_ms
      and not stale_evidence(live, a)
    then
      local cur = best[a.description]
      if cur == nil or a.reaction_ms < cur then best[a.description] = a.reaction_ms end
    end
  end
  return best
end

-- Rank what this player actually struggles with, worst first.
--
-- Two tiers rather than one blended score: "you keep getting this wrong" and
-- "you get this right but slowly" are different problems, the player can tell
-- them apart, and a single number would hide which one a given entry is. Misses
-- come first and hesitations only top up, so a thin history still fills a stage.
--
-- IDENTITY IS THE DESCRIPTION; EVIDENCE IS PER-COMBO. Rows are grouped by
-- description, so a remapped binding keeps its course tier and stays one action
-- rather than splitting into one entity per alias. But whether the player can
-- *execute* it is a fact about a keystroke: pass `opts.combos` (description ->
-- set of currently-bound combos) and answers recorded against a combo that no
-- longer belongs to that action are discarded. Without it, a remap would leave
-- the player being drilled on misses from keys they no longer have.
function M.blind_spots(history_text, opts)
  opts = opts or {}
  local live = opts.combos
  local min_misses = opts.min_misses or M.BLIND_SPOT.min_misses
  local slow_ms    = opts.slow_ms or M.BLIND_SPOT.slow_ms
  local max_ms     = opts.max_ms or M.BLIND_SPOT.max_ms

  local miss, seen, times, order = {}, {}, {}, {}
  for _, a in ipairs(M.parse_history(history_text)) do
    local d = a.description
    -- Stale evidence: this answer was about a combo the action no longer has.
    -- A description absent from `live` entirely is left alone -- the filter drops
    -- it later, and silently rewriting history here would be worse.
    local stale = stale_evidence(live, a)
    if not stale then
      if seen[d] == nil then
        seen[d], miss[d], times[d] = 0, 0, {}
        order[#order + 1] = d
      end
      seen[d] = seen[d] + 1
      if a.outcome ~= "correct" and a.outcome ~= "skipped" then
        miss[d] = miss[d] + 1
      elseif a.reaction_ms and a.reaction_ms > 0 and a.reaction_ms < max_ms then
        times[d][#times[d] + 1] = a.reaction_ms
      end
    end
  end

  local missed, slow = {}, {}
  for _, d in ipairs(order) do
    local mean
    if #times[d] > 0 then
      local sum = 0
      for _, ms in ipairs(times[d]) do sum = sum + ms end
      mean = math.floor(sum / #times[d])
    end
    local row = {
      description = d, misses = miss[d], seen = seen[d],
      mean_ms = mean, samples = #times[d],
    }
    if miss[d] >= min_misses then
      row.reason = "missed"
      missed[#missed + 1] = row
    elseif mean and mean >= slow_ms then
      row.reason = "slow"
      slow[#slow + 1] = row
    end
  end

  -- Deterministic all the way down, so the same history always yields the same
  -- course and a stage is reproducible from its seed.
  table.sort(missed, function(a, b)
    if a.misses ~= b.misses then return a.misses > b.misses end
    local ra, rb = a.misses / a.seen, b.misses / b.seen
    if ra ~= rb then return ra > rb end
    return a.description < b.description
  end)
  table.sort(slow, function(a, b)
    if a.mean_ms ~= b.mean_ms then return a.mean_ms > b.mean_ms end
    return a.description < b.description
  end)

  local out = {}
  for _, r in ipairs(missed) do out[#out + 1] = r end
  for _, r in ipairs(slow) do out[#out + 1] = r end
  return out
end

-- The blind-spot rows that still exist as bindings, worst first.
--
-- Every matching inventory entry is kept, not just the first, so
-- dedupe_by_action can still collect a description's alternate combos. A row
-- with no entry left has been remapped away since it was recorded -- drop it
-- rather than prompt for a combo that no longer works.
function M.filter_blind_spots(inventory, history_text, opts)
  local o = { combos = M.live_combos(inventory) }
  for k, v in pairs(opts or {}) do o[k] = v end

  local rank = {}
  for i, row in ipairs(M.blind_spots(history_text, o)) do
    rank[row.description] = i
  end
  local out = {}
  for _, e in ipairs(inventory) do
    if rank[e.description] then out[#out + 1] = e end
  end
  table.sort(out, function(a, b)
    if rank[a.description] ~= rank[b.description] then
      return rank[a.description] < rank[b.description]
    end
    return (a.combo or "") < (b.combo or "")
  end)
  return out
end

-- A backdrop named in courses.lua, checked for shape and nothing else.
--
-- Every shipped course wears a theme background, and a course you write
-- yourself had no way to name one: it fell through to DEFAULT_SCENE, so the
-- course you play most opened on the same picture as no course at all.
--
-- WHETHER THE THEME IS INSTALLED IS NOT CHECKED HERE, on purpose. core.lua
-- stays off the filesystem, and lib/scene.lua already answers that question the
-- same way for a shipped course as for this one: a theme this machine does not
-- have resolves to nil and the game draws its own sky.
--
-- A malformed scene costs the course its picture, not the course. Patterns are
-- what a drill IS and are refused loudly; dimming is decoration. The shipped
-- scrims run 0.42 to 0.64, and one outside that range is allowed because it is
-- a taste rather than a bound, but 0 and 1 are not: either end is a screen you
-- cannot read.
local function user_scene(name, scene, problems)
  if scene == nil then return nil end
  local why
  if type(scene) ~= "table" then
    why = "is not a table"
  elseif type(scene.theme) ~= "string" or scene.theme == "" then
    why = "names no theme"
  elseif type(scene.file) ~= "string" or scene.file == "" then
    why = "names no background file"
  elseif scene.scrim ~= nil and
         (type(scene.scrim) ~= "number" or scene.scrim <= 0 or scene.scrim >= 1) then
    why = "has a scrim that is not between 0 and 1"
  end
  if why then
    problems[#problems + 1] =
      ("the backdrop on course '%s' %s, so it keeps the default one"):format(name, why)
    return nil
  end
  return {
    theme = scene.theme,
    file  = scene.file,
    scrim = scene.scrim or M.DEFAULT_SCENE.scrim,
  }
end

-- Merge user-defined courses over the built-ins.
--
-- The curated tiers are one person's judgment about what matters, and a
-- newcomer cannot see what is MISSING from them. This is the escape hatch: a
-- player can add a course for their own work, or replace a shipped one whose
-- idea of "daily" is not theirs.
--
-- Every entry is validated before it is accepted. A course with no usable
-- patterns would filter the bank down to nothing, and the engine's empty-pool
-- fallback would then hand over the whole 200-binding inventory, a silent and
-- baffling result from a typo in a config file. Reject it loudly instead.
--
-- Returns the number merged, and a list of complaints for the caller to show.
function M.merge_courses(defs)
  local added, problems = 0, {}
  if type(defs) ~= "table" then
    return 0, { "courses file did not return a table" }
  end
  for name, course in pairs(defs) do
    local why
    if type(name) ~= "string" or name == "" then
      why = "course names must be non-empty strings"
    elseif type(course) ~= "table" then
      why = ("course '%s' is not a table"):format(tostring(name))
    elseif M.COURSES[name] and M.COURSES[name].dynamic then
      -- Blind Spots computes its entries; a pattern list cannot express it.
      why = ("'%s' is a generated course and cannot be redefined"):format(name)
    elseif type(course.patterns) ~= "table" or #course.patterns == 0 then
      why = ("course '%s' has no patterns"):format(name)
    else
      for _, pat in ipairs(course.patterns) do
        if type(pat) ~= "string" then
          why = ("course '%s' has a non-string pattern"):format(name)
          break
        end
        -- Best-effort only, and deliberately so. Lua validates patterns
        -- LAZILY: "^(unclosed" raises "unfinished capture" when a match
        -- engages, but probing it against a non-matching string returns clean.
        -- So this catches the obvious breakage early, and safe_match below is
        -- what actually guarantees a bad pattern cannot take a stage down.
        local ok = pcall(string.match, "probe", pat)
        if not ok then
          why = ("course '%s' has an invalid pattern: %s"):format(name, pat)
          break
        end
      end
    end
    if why then
      problems[#problems + 1] = why
    else
      M.COURSES[name] = {
        label = tostring(course.label or name),
        note = course.note and tostring(course.note) or nil,
        patterns = course.patterns,
        scene = user_scene(name, course.scene, problems),
      }
      added = added + 1
    end
  end
  return added, problems
end

-- A pattern error means "no match", never a crash.
--
-- Patterns can now come from a user's config file, and Lua only rejects a
-- malformed one at the moment a match engages -- which would be partway through
-- building a stage, taking the whole game down for a typo. A pattern that
-- throws is dropped from the course instead, once, so the failure costs the
-- entries it would have matched and nothing else.
local function safe_match(text, pattern)
  local ok, hit = pcall(string.match, text, pattern)
  return ok and hit ~= nil
end

M.safe_match = safe_match

-- Entries whose description matches any pattern in the named course.
--
-- `history_text` is only read by dynamic courses; the curated tiers ignore it,
-- so every existing caller keeps working unchanged.
function M.filter_course(inventory, course_name, history_text)
  local course = M.COURSES[course_name]
  if not course then return inventory end
  if course.dynamic then return M.filter_blind_spots(inventory, history_text) end
  local out = {}
  for _, entry in ipairs(inventory) do
    for _, pattern in ipairs(course.patterns) do
      if safe_match(entry.description, pattern) then
        out[#out + 1] = entry
        break
      end
    end
  end
  return out
end

-- Everything the player has not given up on.
--
-- Applied LAST, over whatever a course selected, so it holds for every course
-- including one somebody wrote themselves. A course that ends up empty because
-- of this says so through the same empty-course screen as any other: the game
-- refuses to start rather than quietly asking retired questions anyway.
function M.without_retired(inventory, history_text)
  local retired = M.retired_actions(history_text)
  if next(retired) == nil then return inventory end
  local out = {}
  for _, entry in ipairs(inventory) do
    if not retired[entry.description] then out[#out + 1] = entry end
  end
  return out
end

-- The order courses are offered in, which is a decision rather than an accident.
--
-- It was alphabetical, so Service Park sat fifth of nine, between Endurance and
-- System, purely because of how it is spelled. Cycling with C should feel like a
-- tour from the things you do constantly out to the things you barely touch, and
-- alphabetical order is not that.
--
-- The sequence is the cadence the design log tiers courses by: dozens a day,
-- then several, then weekly, then rare. The last two are not frequency tiers at
-- all, which is why they sit outside it: Blind Spots is generated from your own
-- history rather than curated, and Service Park is where the odd-shaped
-- leftovers went when the coverage pass found a quarter of the keymap in no
-- course at all.
M.COURSE_ORDER = {
  "daily-driver",   -- dozens a day
  "the-commute",    -- several a day
  "apps",           -- the one where a mouse habit costs most
  "track-day",      -- weekly
  "system",         -- the machine itself
  "endurance",      -- rare, the far corners
  "blind-spots",    -- yours, built from what you miss
}

-- Always last, whatever else exists. It is the catch-all, so anything that
-- arrives later belongs in front of it rather than behind it.
M.COURSE_TAIL = "service-park"

function M.course_names()
  local seen, names = {}, {}
  for _, name in ipairs(M.COURSE_ORDER) do
    if M.COURSES[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  seen[M.COURSE_TAIL] = true

  -- Anything the order does not mention, which is how a course written in
  -- ~/.config/omashift/courses.lua reaches the menu. Alphabetical among
  -- themselves, after the shipped set, and still in front of the catch-all.
  local extra = {}
  for name in pairs(M.COURSES) do
    if not seen[name] then extra[#extra + 1] = name end
  end
  table.sort(extra)
  for _, name in ipairs(extra) do names[#names + 1] = name end

  if M.COURSES[M.COURSE_TAIL] then names[#names + 1] = M.COURSE_TAIL end
  return names
end

-- name -> label, for anything that has to show a list to a human.
function M.course_label(name)
  local c = M.COURSES[name]
  return c and c.label or tostring(name)
end

-- ---------------------------------------------------------------------------
-- The co-driver (learning mode)
-- ---------------------------------------------------------------------------

-- Wait, and your co-driver reads you in. Progressive so waiting is not binary:
-- modifier set first, then the full combo. A called stage still trains and still
-- scores, but cannot set a personal best.
-- Defaults only. Real values come from the stage, so they are tunable per run
-- and per user without editing code. "how long before the co-driver speaks" is
-- a feel decision, not a constant.
M.CODRIVER_MODS_MS  = 2000
M.CODRIVER_FULL_MS  = 4500

-- opts may carry {mods_ms, full_ms}; anything missing falls back to the
-- defaults. A full_ms below mods_ms would reveal the answer before the hint, so
-- it is clamped rather than trusted.
function M.codriver_timing(opts)
  opts = opts or {}
  local mods = tonumber(opts.mods_ms) or M.CODRIVER_MODS_MS
  local full = tonumber(opts.full_ms) or M.CODRIVER_FULL_MS
  if mods < 0 then mods = 0 end
  if full < mods then full = mods end
  return mods, full
end

function M.hint_for(prompt, elapsed_ms, opts)
  if not prompt or type(elapsed_ms) ~= "number" then return nil end
  local mods_ms, full_ms = M.codriver_timing(opts)
  if elapsed_ms >= full_ms then
    return { level = "full", text = prompt.combo }
  end
  if elapsed_ms >= mods_ms then
    local mods = prompt.combo:match("^(.*)%s%+%s[^%+]+$")
    return { level = "mods", text = (mods or "?") .. " + ?" }
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Spaced repetition (Anki-derived)
-- ---------------------------------------------------------------------------
--
-- Adapted from SM-2, the algorithm behind Anki, with two deliberate departures.
--
-- 1. GRADING IS MEASURED, NOT SELF-REPORTED.
--    Anki must ask "how hard was that?" (Again/Hard/Good/Easy) because it cannot
--    see you think. Omashift already times you, and reaction time is a better
--    difficulty signal than self-report: objective, free, and unfakeable. A
--    250ms answer and a 3-second one are both "correct" and must not be treated
--    alike, or the scheduler learns nothing from the difference.
--
-- 2. TWO TIMESCALES, NOT ONE.
--    SM-2's intervals are tuned for days, where a card is seen once per session.
--    Omashift's loop is seconds long, so the same binding can legitimately recur
--    within one sitting. A straight SM-2 port misbehaves here. So:
--      * LEARNING STEPS run inside a stage, measured in intervening prompts.
--        A fresh miss comes back a few prompts later, while it is still warm.
--        This is Anki's 1m/10m learning steps, re-based onto prompt positions.
--      * REVIEW INTERVALS run across sessions, measured in days, SM-2 proper.
--    An item graduates from steps to intervals once it is answered cleanly.
--
-- Retrieval-before-reveal is preserved by the co-driver's delay: the player must
-- attempt recall before any hint appears. Revealing sooner would destroy the
-- testing effect that makes the whole scheme work.

M.EASE_START   = 2.5    -- SM-2 default
M.EASE_FLOOR   = 1.3    -- SM-2 default; below this an item is pathological
M.EASE_AGAIN   = -0.20
M.EASE_HARD    = -0.15
M.EASE_EASY    =  0.15

-- Anki's graduating intervals, in days.
M.FIRST_INTERVAL  = 1
M.SECOND_INTERVAL = 6

-- Learning steps, in intervening prompts rather than minutes. A lapsed item
-- returns after this many other prompts, while the attempt is still warm.
M.LEARNING_STEPS = { 2, 5 }

M.GRADE = { AGAIN = 0, HARD = 1, GOOD = 2, EASY = 3 }

-- Reaction time and assistance -> an Anki-style grade. This is the bridge
-- between the racing game and the scheduler, and the reason no self-report is
-- needed.
function M.grade_for(result)
  if not result or result.outcome ~= "correct" then return M.GRADE.AGAIN end
  if result.assisted then return M.GRADE.HARD end
  local tier = result.tier
  if tier == "zero-latency" or tier == "on-rails" then return M.GRADE.EASY end
  if tier == "clean" then return M.GRADE.GOOD end
  return M.GRADE.HARD
end

function M.new_item(combo)
  return {
    combo    = combo,
    ease     = M.EASE_START,
    interval = 0,      -- days; 0 means still in learning steps
    due_day  = 0,      -- absolute day number; 0 means due now
    reps     = 0,
    lapses   = 0,
    step     = 1,      -- index into LEARNING_STEPS while not graduated
  }
end

-- Apply a grade to an item. `today` is an absolute day number supplied by the
-- caller. Core never reads a clock, so a test can replay months in a loop.
function M.schedule(item, grade, today)
  item = item or M.new_item("?")
  today = today or 0

  if grade == M.GRADE.AGAIN then
    -- A lapse drops back to learning steps and shrinks ease, so a binding you
    -- keep fumbling stays frequent. This is the whole point of the scheme.
    item.lapses   = item.lapses + 1
    item.ease     = math.max(M.EASE_FLOOR, item.ease + M.EASE_AGAIN)
    item.interval = 0
    item.step     = 1
    item.due_day  = today
    return item
  end

  -- Still in learning steps: advance, or graduate.
  if item.interval == 0 then
    if grade == M.GRADE.HARD then
      item.ease = math.max(M.EASE_FLOOR, item.ease + M.EASE_HARD)
      -- Hard keeps you on the same step rather than advancing.
      item.due_day = today
      return item
    end
    if item.step < #M.LEARNING_STEPS and grade ~= M.GRADE.EASY then
      item.step = item.step + 1
      item.due_day = today
      return item
    end
    -- Graduated.
    item.interval = M.FIRST_INTERVAL
    item.reps     = item.reps + 1
    item.due_day  = today + item.interval
    if grade == M.GRADE.EASY then
      item.ease = item.ease + M.EASE_EASY
    end
    return item
  end

  -- In review. Expanding intervals, scaled by the item's own ease factor.
  -- reps is read BEFORE incrementing: the first review after graduating takes
  -- Anki's second interval (6 days), not ease-scaled growth.
  local first_review = (item.reps == 1)
  item.reps = item.reps + 1
  if grade == M.GRADE.HARD then
    item.ease     = math.max(M.EASE_FLOOR, item.ease + M.EASE_HARD)
    item.interval = math.max(1, math.floor(item.interval * 1.2 + 0.5))
  elseif grade == M.GRADE.EASY then
    item.ease     = item.ease + M.EASE_EASY
    item.interval = math.max(1, math.floor(item.interval * item.ease * 1.3 + 0.5))
  elseif first_review then -- GOOD, first review after graduating
    item.interval = M.SECOND_INTERVAL
  else -- GOOD
    item.interval = math.max(1, math.floor(item.interval * item.ease + 0.5))
  end
  item.due_day = today + item.interval
  return item
end

-- Queue order, mirroring Anki's: overdue reviews first, then unseen items, then
-- anything else as filler.
--
-- The unseen tier is not an afterthought. An item you have never been shown has
-- no interval at all, which is exactly the high-utility / low-exposure set that
-- Blind Spots is meant to surface. The scheduler produces that list for free.
function M.select_due(inventory, schedule, today, count)
  schedule = schedule or {}
  today = today or 0
  local due, unseen, rest = {}, {}, {}
  for _, entry in ipairs(inventory) do
    local item = schedule[entry.combo]
    if not item then
      unseen[#unseen + 1] = entry
    elseif item.due_day <= today then
      due[#due + 1] = { entry = entry, overdue = today - item.due_day }
    else
      rest[#rest + 1] = entry
    end
  end
  -- Most overdue first; ties broken by combo so the order is deterministic.
  table.sort(due, function(a, b)
    if a.overdue ~= b.overdue then return a.overdue > b.overdue end
    return a.entry.combo < b.entry.combo
  end)

  local out = {}
  for _, d in ipairs(due) do
    if #out >= count then return out end
    out[#out + 1] = d.entry
  end
  for _, e in ipairs(unseen) do
    if #out >= count then return out end
    out[#out + 1] = e
  end
  for _, e in ipairs(rest) do
    if #out >= count then return out end
    out[#out + 1] = e
  end
  return out
end

-- How far ahead a missed note comes back.
--
-- It used to be a constant, so a miss ALWAYS returned as the second prompt
-- after it. That is not a memory test: you brace for it, answer from short-term
-- recall, and learn nothing. The requeue rewards prediction instead of the
-- retrieval it exists to force.
--
-- The range is bounded at both ends for different reasons. Sooner than 2 and
-- the answer is still on screen in your head; later than 5 and it is not a
-- within-stage requeue any more, which is what the spaced-repetition schedule
-- already handles on the other timescale.
M.REQUEUE_GAP = { min = 2, max = 5 }

-- How many times one note may come back inside a single stage.
--
-- Uncapped this is a loop with no exit: a real Endurance run asked ten notes
-- and delivered twenty-three, because a binding the player could not press came
-- back every time it was missed and missing it was the only outcome available.
M.REQUEUE_LIMIT = 2

-- How many times you have to skip the same note before the game stops asking.
--
-- WHY THIS EXISTS. A keymap can contain a binding this keyboard cannot produce:
-- a laptop with no PrintScreen key had three, and they came round forever. A
-- skip gets you past one today, but the note is still in the bank tomorrow, and
-- a trainer that keeps asking a question you have twice said you cannot answer
-- is not training anything.
--
-- TWO, NOT ONE. One skip is a decision made in a hurry, mid-stage, possibly by
-- the wrong finger. Two is a pattern, and the second one is announced on
-- screen, so nothing is removed from your rotation without you being told.
M.RETIRE_AFTER_SKIPS = 2

-- Per-stage RNG, so a stage remains reproducible from its seed. Same LCG as the
-- shuffle above, and for the same reason: math.random's implementation differs
-- between Lua versions, and a stage that replays differently on another machine
-- would make the ghost and every recorded run non-comparable.
local function stage_rand(state, n)
  state.rng = ((state.rng or 1) * 1103515245 + 12345) % 2147483648
  -- HIGH bits, not low. An LCG's low bits have a tiny period -- taking
  -- `rng % 4` here produced 4,5,2,3,4,5,2,3 forever, which is a different
  -- predictable pattern rather than none, and would have shipped as a fix.
  return (math.floor(state.rng / 65536) % n) + 1
end

M.stage_rand = stage_rand

-- Re-insert a lapsed prompt later in the CURRENT stage. This is the
-- within-stage half of the two-timescale scheme: a fresh miss comes back while
-- it is still warm, rather than waiting a day.
--
-- `gap` is optional and exists for tests; leaving it out is the real behavior.
function M.requeue(state, entry, gap)
  -- TWICE PER NOTE PER STAGE, AND NO MORE.
  --
  -- Uncapped, this is a loop with no exit. A real Endurance run asked ten notes
  -- and delivered twenty-three, because a binding the player physically could
  -- not press (SUPER + CTRL + PRINT, on a laptop with no PrintScreen key) came
  -- back every time it was missed, and missing it was the only outcome
  -- available. The stage could not end, and the player sat and waited for the
  -- idle release.
  --
  -- Two, not one. A single return is enough to break the loop but too tight to
  -- teach: missing something, seeing it again, and missing it again is a
  -- perfectly ordinary way to learn a chord, and the note you get wrong twice
  -- is precisely the one worth a third look while the stage is still warm.
  -- Past that the schedule owns it, on a timescale of days rather than minutes.
  --
  -- The bound this buys is what matters: a stage can at most triple, and it
  -- always ends.
  state.requeued = state.requeued or {}
  local key = entry.description or entry.combo
  local seen = state.requeued[key] or 0
  if seen >= M.REQUEUE_LIMIT then return nil end
  state.requeued[key] = seen + 1

  if not gap then
    local lo, hi = M.REQUEUE_GAP.min, M.REQUEUE_GAP.max
    gap = lo + stage_rand(state, hi - lo + 1) - 1
  end
  local target = math.min(state.index + gap, #state.prompts + 1)
  table.insert(state.prompts, target, entry)
  return target
end

-- Serialize a schedule to a Lua module. Hyprland's Lua sandbox has no JSON
-- parser, so persisted state is handed back as code, the same way the question
-- bank is.
function M.serialize_schedule(schedule)
  local combos = {}
  for combo in pairs(schedule) do combos[#combos + 1] = combo end
  table.sort(combos)   -- deterministic output, so diffs are readable
  local out = { "-- Generated by Omashift. Do not edit.", "return {" }
  for _, combo in ipairs(combos) do
    local i = schedule[combo]
    out[#out + 1] = ("  [%q] = { ease = %.4f, interval = %d, due_day = %d, reps = %d, lapses = %d, step = %d },")
      :format(combo, i.ease, i.interval, i.due_day, i.reps, i.lapses, i.step)
  end
  out[#out + 1] = "}"
  return table.concat(out, "\n") .. "\n"
end

-- ---------------------------------------------------------------------------
-- Stage construction
-- ---------------------------------------------------------------------------

-- Deterministic shuffle: caller supplies the seed so tests can replay a stage.
local function shuffled(list, seed)
  local out = {}
  for i, v in ipairs(list) do out[i] = v end
  local rng = seed
  -- Own LCG so results do not depend on the host Lua's math.random, which
  -- differs between 5.3 and 5.4+ and would make a seeded stage replay
  -- differently on another machine.
  --
  -- HIGH bits, not low. `rng % n` reads an LCG's least significant bits, which
  -- have a very short period, and the bias was severe rather than theoretical:
  -- over 2000 seeds the first item of an 8-entry bank led 466 times and the
  -- last 65, against an ideal of 250. That is not a fairness nicety. It means
  -- some bindings were being drilled several times as often as others.
  local function next_rand(n)
    rng = (rng * 1103515245 + 12345) % 2147483648
    return (math.floor(rng / 65536) % n) + 1
  end
  for i = #out, 2, -1 do
    local j = next_rand(i)
    out[i], out[j] = out[j], out[i]
  end
  return out
end

M.shuffled = shuffled

-- No course may be modifier-homogeneous, and consecutive prompts must not share
-- a modmask. Frequency and simple modifiers correlate (Omarchy gives common
-- actions easy combos), so without this the answer leaks: the player pre-loads
-- the modifiers and only reaction-times the key.
function M.spread_modmask(entries)
  local out, deferred = {}, {}
  local last
  for _, e in ipairs(entries) do
    if last ~= nil and e.modmask == last and #deferred < #entries then
      deferred[#deferred + 1] = e
    else
      out[#out + 1] = e
      last = e.modmask
      -- Re-admit anything parked earlier that no longer collides.
      for i = #deferred, 1, -1 do
        if deferred[i].modmask ~= last then
          out[#out + 1] = deferred[i]
          last = deferred[i].modmask
          table.remove(deferred, i)
        end
      end
    end
  end
  for _, e in ipairs(deferred) do out[#out + 1] = e end
  return out
end

-- Collapse bindings that do the same thing into one entry carrying its
-- alternates. Omarchy describes several combos identically. "Browser" is both
-- SUPER+SHIFT+RETURN and SUPER+SHIFT+B, and asking the same action twice in a
-- stage reads as a bug even when both answers are accepted.
function M.dedupe_by_action(inventory)
  local out, index = {}, {}
  for _, e in ipairs(inventory) do
    local seen = index[e.description]
    if seen then
      seen.alts = seen.alts or {}
      seen.alts[#seen.alts + 1] = e.combo
    else
      local copy = { combo = e.combo, key = e.key, modmask = e.modmask,
                     description = e.description, alts = nil }
      index[e.description] = copy
      out[#out + 1] = copy
    end
  end
  return out
end

-- Build a stage: a shuffled, modmask-spread slice of the inventory.
function M.new_stage(inventory, opts)
  opts = opts or {}
  local length = opts.length or 10
  local seed = opts.seed or 1
  local picked = shuffled(M.dedupe_by_action(inventory), seed)
  local slice = {}
  for i = 1, math.min(length, #picked) do slice[i] = picked[i] end
  local ordered = M.spread_modmask(slice)
  return {
    base_length  = #ordered,
    prompts      = ordered,
    index        = 0,
    gear         = M.MIN_GEAR,
    points       = 0,
    streak       = 0,
    results      = {},
    shown_at     = nil,
    finished     = false,
    assisted     = false,   -- true once the co-driver has called anything
    course       = opts.course,
    rng          = seed,
    difficulty   = opts.difficulty,
    tier_scale   = opts.tier_scale,
    ghost        = opts.ghost or {},
    codriver     = { mods_ms = opts.codriver_mods_ms, full_ms = opts.codriver_full_ms },
  }
end

function M.next_prompt(state, now_ms)
  state.index = state.index + 1
  if state.index > #state.prompts then
    state.finished = true
    state.shown_at = nil
    return nil
  end
  state.shown_at = now_ms
  return state.prompts[state.index]
end

function M.current(state)
  return state.prompts[state.index]
end

-- ---------------------------------------------------------------------------
-- Answering
-- ---------------------------------------------------------------------------

-- Returns a result table. `combo` is the combo the player actually pressed;
-- `known_description` is its description if it is a real binding, which is what
-- makes the wrong-answer feedback a teaching moment rather than a buzzer.
function M.answer(state, combo, now_ms, known_description)
  local prompt = M.current(state)
  if not prompt or state.finished then
    return { outcome = "no-prompt" }
  end

  local reaction = (state.shown_at and now_ms) and (now_ms - state.shown_at) or nil

  -- Accept ANY binding that does the same thing. Omarchy describes more than one
  -- combo identically. "Browser" is both SUPER+SHIFT+RETURN and SUPER+SHIFT+B,
  -- so demanding one specific combo marks a genuinely correct answer wrong. A
  -- real playtest lost three prompts in a row to exactly this, and requeue kept
  -- handing the unwinnable note back.
  local equivalent = known_description ~= nil
    and known_description == prompt.description
  if combo == prompt.combo or equivalent then
    local tier = M.tier_for(reaction, state.tier_scale)
    -- Momentum, not mere correctness. A slow answer is not a crash, so it does
    -- not downshift -- but momentum is exactly what it costs, so the chain
    -- breaks. Only an off sends you back a gear.
    if M.tier_rank(tier.name) <= M.tier_rank(M.UPSHIFT_TIER) then
      state.streak = state.streak + 1
      if state.streak % 2 == 0 then state.gear = M.upshift(state.gear) end
    else
      state.streak = 0
    end
    local gained = tier.points * M.multiplier(state.gear)
    state.points = state.points + gained
    -- Racing against yourself. A note with no ghost yet is not announced as a
    -- best: on a new player every note would be one, and a banner that fires
    -- constantly stops meaning anything. It becomes the ghost for next time
    -- regardless, because personal_bests reads it back out of the history.
    local ghost_ms = state.ghost and state.ghost[prompt.description]
    local result = {
      outcome     = "correct",
      ghost_ms    = ghost_ms,
      ghost_delta = ghost_ms and (reaction - ghost_ms) or nil,
      -- Provisional: the stage is disqualified from setting bests the moment
      -- the co-driver calls anything, and it may still call later. The written
      -- record is what personal_bests actually trusts.
      best        = (ghost_ms ~= nil and reaction < ghost_ms and not state.assisted) or nil,
      combo       = combo,
      expected    = prompt.combo,
      description = prompt.description,
      reaction_ms = reaction,
      tier        = tier.name,
      praise      = tier.praise,
      points      = gained,
      gear        = state.gear,
    }
    state.results[#state.results + 1] = result
    return result
  end

  -- Wrong. An "off" costs momentum rather than only time, which is a sharper
  -- disincentive to mashing modifiers than a flat penalty.
  state.streak = 0
  state.gear = M.downshift(state.gear)
  local result = {
    outcome     = "off",
    combo       = combo,
    expected    = prompt.combo,
    description = prompt.description,
    reaction_ms = reaction,
    -- The teaching signal: name what they actually triggered.
    pressed_was = known_description,
    points      = 0,
    gear        = state.gear,
  }
  state.results[#state.results + 1] = result
  return result
end

-- Beyond this, the player was not thinking. They were away. The co-driver has
-- revealed the whole combo by ~8s, so a 4-minute "reaction" is an interruption.
-- Including one drags a stage average from ~2s to 42s and makes it meaningless.
-- Give up on the current note.
--
-- WHY A GAME NEEDS THIS. Not every prompt is answerable. A keymap can hold a
-- binding whose key the keyboard does not have, and a laptop with no
-- PrintScreen key has three of them: the note cannot be answered, missing it
-- used to requeue it, and the only way out was to sit through the idle release.
-- That is not a hard question, it is a locked door.
--
-- NOT AN OFF. An off means you pressed the wrong thing: it costs a gear and it
-- feeds Blind Spots, so the game drills it harder next time. Doing that to a
-- chord nobody can press would aim the whole training loop at the one note it
-- can never teach. A skip costs the streak, because you did not answer it, and
-- nothing else.
function M.skip(state)
  local prompt = M.current(state)
  if not prompt or state.finished then
    return { outcome = "no-prompt" }
  end
  state.streak = 0
  local result = {
    outcome     = "skipped",
    expected    = prompt.combo,
    description = prompt.description,
    points      = 0,
    gear        = state.gear,
  }
  state.results[#state.results + 1] = result
  return result
end

M.AWAY_MS = 30000

-- How the stage's answers fell across the ladder, fastest tier first.
--
-- Splits say WHICH KIND of thing you were slow at; this says HOW SLOW you were
-- overall, on the same ladder the tiers were calibrated against. It is also the
-- readout that makes a difficulty change legible: the same play on easy and on
-- hard produces a visibly different shape, where a single average does not.
--
-- Every tier is returned, including empty ones. A tier you never reach is the
-- information. An absent row would just look like it does not exist.
function M.tier_counts(state)
  local counts, total = {}, 0
  for _, r in ipairs((state or {}).results or {}) do
    if r.outcome == "correct" and r.tier then
      counts[r.tier] = (counts[r.tier] or 0) + 1
      total = total + 1
    end
  end
  local out = {}
  for _, tier in ipairs(M.TIERS) do
    out[#out + 1] = {
      name = tier.name,
      count = counts[tier.name] or 0,
      share = total > 0 and ((counts[tier.name] or 0) / total) or 0,
    }
  end
  return out, total
end

function M.summary(state)
  local correct, offs, total_reaction, counted, away = 0, 0, 0, 0, 0
  local ghost_notes, ghost_beat, ghost_delta = 0, 0, 0
  local fastest
  for _, r in ipairs(state.results) do
    if r.outcome == "correct" then
      correct = correct + 1
      if r.ghost_delta then
        ghost_notes = ghost_notes + 1
        ghost_delta = ghost_delta + r.ghost_delta
        if r.ghost_delta < 0 then ghost_beat = ghost_beat + 1 end
      end
      if r.reaction_ms then
        if r.reaction_ms >= M.AWAY_MS then
          away = away + 1
        else
          total_reaction = total_reaction + r.reaction_ms
          counted = counted + 1
          if fastest == nil or r.reaction_ms < fastest then fastest = r.reaction_ms end
        end
      end
    elseif r.outcome == "off" then
      offs = offs + 1
    end
  end
  return {
    prompts      = #state.prompts,
    base_prompts = state.base_length or #state.prompts,
    requeues     = #state.prompts - (state.base_length or #state.prompts),
    answered     = #state.results,
    correct      = correct,
    offs         = offs,
    points       = state.points,
    gear         = state.gear,
    stage_ms     = total_reaction,
    average_ms   = counted > 0 and (total_reaction / counted) or nil,
    -- Average over equal distances is total distance over total time, which is
    -- what this is -- not the mean of the individual speeds, which would be
    -- the wrong average and would flatter a stage with one very fast note.
    average_kmh  = counted > 0 and M.speed_kmh(total_reaction / counted) or nil,
    top_kmh      = fastest and M.speed_kmh(fastest) or nil,
    fastest_ms   = fastest,
    away         = away,
    clean        = (offs == 0 and correct == #state.prompts),
    ghost_notes  = ghost_notes,
    ghost_beat   = ghost_beat,
    -- Sum of deltas over the notes that HAVE a ghost. Comparing full stage
    -- times would be meaningless: two stages rarely contain the same notes.
    ghost_delta  = ghost_notes > 0 and ghost_delta or nil,
  }
end


-- ---------------------------------------------------------------------------
-- Splits
-- ---------------------------------------------------------------------------

-- Rally splits fall on binding CATEGORIES, so a split time says *which kind* of
-- thing you are slow at. A stage total tells you that you were slow; a split
-- tells you it was window management. That difference is what makes this a
-- training tool rather than a scoreboard.
--
-- Matched on description, like courses, so the category survives a remapping.
-- Order matters: the first pattern to match wins, so specific beats general.
M.CATEGORIES = {
  { name = "Workspaces", patterns = { "workspace", "^Next workspace", "^Former workspace" } },
  { name = "Windows",    patterns = { "window", "^Full screen", "^Full width", "^Toggle window",
                                      "^Expand ", "^Shrink ", "^Restore ", "^Pseudo", "^Swap " } },
  { name = "Monitors",   patterns = { "monitor", "^Display", "^Monitor scaling" } },
  { name = "Clipboard",  patterns = { "^Universal ", "^Clipboard", "^Copy ", "^Emojis" } },
  { name = "Capture",    patterns = { "^Screenshot", "^Screenrecording", "^Color picker",
                                      "^Extract text", "^Capture menu", "Video from Web App" } },
  { name = "Media",      patterns = { "^Volume", "^Brightness", "track$", "^Mute", "^Switch media",
                                      "^Switch audio", "^Audio", "^Play" } },
  { name = "System",     patterns = { "menu$", "^Bluetooth", "^Activity", "^Agent", "^Background",
                                      "^Bar panel", "^Clear reminders", "notification",
                                      "^Toggle ", "^Keybindings", "^Lock", "^Theme" } },
  { name = "Apps",       patterns = { "." } },   -- everything else launches something
}

function M.category_of(entry)
  local d = (entry and entry.description) or ""
  for _, cat in ipairs(M.CATEGORIES) do
    for _, pattern in ipairs(cat.patterns) do
      if d:match(pattern) then return cat.name end
    end
  end
  return "Apps"
end

-- Per-category breakdown of a stage. Away answers are excluded from timing for
-- the same reason they are excluded from the average: they are interruptions.
function M.splits(state)
  local by, order = {}, {}
  for _, r in ipairs(state.results or {}) do
    local name = M.category_of(r)
    if not by[name] then
      by[name] = { name = name, asked = 0, correct = 0, offs = 0, total_ms = 0, timed = 0 }
      order[#order + 1] = name
    end
    local sp = by[name]
    sp.asked = sp.asked + 1
    if r.outcome == "correct" then
      sp.correct = sp.correct + 1
      if r.reaction_ms and r.reaction_ms < M.AWAY_MS then
        sp.total_ms = sp.total_ms + r.reaction_ms
        sp.timed = sp.timed + 1
      end
    elseif r.outcome == "off" then
      sp.offs = sp.offs + 1
    end
  end
  local out = {}
  for _, name in ipairs(order) do
    local sp = by[name]
    sp.average_ms = sp.timed > 0 and (sp.total_ms / sp.timed) or nil
    out[#out + 1] = sp
  end
  -- Slowest first: the point of a split screen is to show where the time went.
  table.sort(out, function(a, b)
    return (a.average_ms or 0) > (b.average_ms or 0)
  end)
  return out
end

-- ---------------------------------------------------------------------------
-- The quattro HUD
-- ---------------------------------------------------------------------------

-- Four driven wheels, four modifiers. The name means four, and there are
-- exactly four: SUPER, CTRL, ALT, SHIFT.
--
-- This is the rare element that is both theme and function. Holding the wrong
-- modifier set is the most common way to miss a note. John's cut/copy and
-- three-way menu confusions are both modifier errors, so showing live modifier
-- state is the single most useful feedback the game can give, and it happens to
-- be exactly on-theme.
M.WHEEL_ORDER = { "SUPER", "CTRL", "ALT", "SHIFT" }

-- held: { SUPER = bool, CTRL = bool, ALT = bool, SHIFT = bool }
-- Returns the two rows of a 2x2 wheel layout, read like a car from above.
function M.wheels(held)
  held = held or {}
  local function wheel(name)
    return held[name] and "(#)" or "( )"
  end
  local function label(name)
    return held[name] and name or string.rep(" ", #name)
  end
  return {
    ("  %s %-5s      %s %-5s"):format(wheel("SUPER"), label("SUPER"),
                                      wheel("CTRL"),  label("CTRL")),
    ("  %s %-5s      %s %-5s"):format(wheel("ALT"),   label("ALT"),
                                      wheel("SHIFT"), label("SHIFT")),
  }
end

-- All four down is full quattro. Every wheel is driven.
function M.full_quattro(held)
  held = held or {}
  for _, name in ipairs(M.WHEEL_ORDER) do
    if not held[name] then return false end
  end
  return true
end


-- ---------------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------------

-- Minimal JSON string escaping. Hyprland's Lua sandbox has no JSON library, and
-- descriptions contain quotes, slashes and non-ASCII, so this cannot be skipped.
function M.json_escape(v)
  return (tostring(v or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t"))
end

local function jstr(v) return '"' .. M.json_escape(v) .. '"' end
local function jnum(v) return (type(v) == "number") and string.format("%d", v) or "null" end
local function jbool(v) return v and "true" or "false" end

-- json_escape's counterpart: reading the file back. Not a general JSON parser --
-- it walks the `answers` array that history_record writes below and pulls the
-- three fields Blind Spots needs.
--
-- It is escape-aware on purpose. The obvious one-liner,
-- `line:gmatch('"description":"([^"]*)"')`, truncates on the first escaped
-- quote and then mis-attributes every later field on that line -- a silent
-- wrong answer, not a crash, which is the expensive kind.
local ESCAPES = {
  n = "\n", r = "\r", t = "\t", b = "\b", f = "\f",
  ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
}

-- Decode the JSON string starting at the quote on index `i`. Returns the value
-- and the index just past the closing quote.
local function read_string(s, i)
  local out, j = {}, i + 1
  while j <= #s do
    local c = s:sub(j, j)
    if c == "\\" then
      local e = s:sub(j + 1, j + 1)
      if e == "u" then
        -- \uXXXX is passed through verbatim rather than decoded. Nothing in the
        -- binding inventory carries one, and a faithful passthrough beats a
        -- wrong decode.
        out[#out + 1] = s:sub(j, j + 5)
        j = j + 6
      else
        out[#out + 1] = ESCAPES[e] or e
        j = j + 2
      end
    elseif c == '"' then
      return table.concat(out), j + 1
    else
      out[#out + 1] = c
      j = j + 1
    end
  end
  return table.concat(out), j -- unterminated line: take what is there
end

-- Top-level `{...}` substrings of an array body. Strings are skipped through
-- read_string so a brace inside a description cannot close an object early.
local function split_objects(s)
  local out, depth, start, i = {}, 0, nil, 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      local _, nxt = read_string(s, i)
      i = nxt
    else
      if c == "{" then
        depth = depth + 1
        if depth == 1 then start = i end
      elseif c == "}" then
        depth = depth - 1
        if depth == 0 and start then
          out[#out + 1] = s:sub(start, i)
          start = nil
        end
      end
      i = i + 1
    end
  end
  return out
end

-- Flat key => value for one JSON object. Values are strings, numbers, booleans
-- or absent; nested containers do not appear in an answer record.
local function read_pairs(s)
  local t, i = {}, 1
  while i <= #s do
    if s:sub(i, i) == '"' then
      local key, nxt = read_string(s, i)
      local _, vstart = s:find("^%s*:%s*", nxt)
      if vstart then
        vstart = vstart + 1
        if s:sub(vstart, vstart) == '"' then
          local val, after = read_string(s, vstart)
          t[key] = val
          i = after
        else
          local raw, after = s:match("^([^,}]*)()", vstart)
          raw = (raw or ""):gsub("%s+$", "")
          if raw == "true" then t[key] = true
          elseif raw == "false" then t[key] = false
          elseif raw ~= "null" then t[key] = tonumber(raw) end
          i = after
        end
      else
        i = nxt
      end
    else
      i = i + 1
    end
  end
  return t
end

-- Every answer across every recorded stage, oldest first.
--
-- Only the `answers` array is read. The stage-level fields are deliberately
-- skipped: a record carries its own "course" key, and scanning the whole line
-- would read that as an answer.
function M.parse_history(text)
  local out = {}
  for line in tostring(text or ""):gmatch("[^\n]+") do
    local akey = line:find('"answers"', 1, true)
    local _, abody = line:find('"answers"%s*:%s*%[')
    if abody then
      -- The stage header, read separately. `assisted` lives here and nowhere
      -- else, and it is what disqualifies a run from setting a personal best.
      local head = read_pairs(line:sub(1, akey - 1))
      for _, obj in ipairs(split_objects(line:sub(abody))) do
        local a = read_pairs(obj)
        if a.description and a.description ~= "" then
          out[#out + 1] = {
            combo       = a.combo,
            description = a.description,
            outcome     = a.outcome,
            reaction_ms = tonumber(a.reaction_ms),
            assisted    = head.assisted == true,
            difficulty  = head.difficulty,
            course      = head.course,
          }
        end
      end
    end
  end
  return out
end

-- Whole runs: the stage header WITH its answers, in the order they were played.
-- parse_history flattens every answer into one list, which is what the readers
-- want; the Cabinet needs the stages kept apart, because a trophy is earned by
-- a run rather than by an answer.
function M.parse_runs(text)
  local out = {}
  for line in tostring(text or ""):gmatch("[^\n]+") do
    local akey = line:find('"answers"', 1, true)
    local _, abody = line:find('"answers"%s*:%s*%[')
    if akey and abody then
      local run = read_pairs(line:sub(1, akey - 1))
      run.answers = {}
      for _, obj in ipairs(split_objects(line:sub(abody))) do
        local a = read_pairs(obj)
        if a.description and a.description ~= "" then
          run.answers[#run.answers + 1] = {
            combo = a.combo, description = a.description,
            outcome = a.outcome, reaction_ms = tonumber(a.reaction_ms),
          }
        end
      end
      run.line = line
      out[#out + 1] = run
    end
  end
  return out
end

-- Stage headers only, one per recorded run. The per-answer reader above throws
-- these away; the Cabinet needs them, because "beating your previous time" is a
-- fact about a stage rather than an answer.
function M.parse_stages(text)
  local out = {}
  for line in tostring(text or ""):gmatch("[^\n]+") do
    local akey = line:find('"answers"', 1, true)
    if akey then
      local head = read_pairs(line:sub(1, akey - 1))
      if head.stamp or head.course then out[#out + 1] = head end
    end
  end
  return out
end

-- Everything the engine needs to know about PRIOR play, from ONE parse.
--
-- This exists for a performance reason that turned into a correctness one.
-- Hyprland's Lua sandbox caps how long a single timer callback may run, and the
-- stage-completion callback was parsing the whole history file three times over
-- once for misses, once for the course average, once for the ghost, on top of
-- scoring, the cabinet, and rendering. At 28 stages that reliably blew the
-- budget, the callback was killed partway, and the results screen never reached
-- the display. It grows with every stage played, so it could only get worse.
--
-- Call this ONCE at arm time, where a few milliseconds are invisible, and the
-- completion path becomes pure arithmetic on values already in memory.
function M.history_facts(text, opts)
  opts = opts or {}
  local answers = M.parse_history(text)
  local live = opts.combos
  local max_ms = M.BLIND_SPOT.max_ms

  local missed, best = {}, {}
  for _, a in ipairs(answers) do
    if a.outcome ~= "correct" and a.outcome ~= "skipped" then
      missed[a.description] = true
    elseif not a.assisted
      and a.reaction_ms and a.reaction_ms > 0 and a.reaction_ms < max_ms
      and not stale_evidence(live, a)
    then
      local cur = best[a.description]
      if cur == nil or a.reaction_ms < cur then best[a.description] = a.reaction_ms end
    end
  end

  -- Best completed average per course, so "beating your previous time" costs
  -- nothing at the moment it is judged.
  local course_best = {}
  for _, st in ipairs(M.parse_stages(text)) do
    if st.completed == true and type(st.average_ms) == "number" and st.course then
      local cur = course_best[st.course]
      if cur == nil or st.average_ms < cur then course_best[st.course] = st.average_ms end
    end
  end

  return { previously_missed = missed, ghost = best, course_best = course_best }
end

-- Actions the player has given up on often enough that the game should stop
-- asking. Read from the same history as everything else, so there is no second
-- source of truth and deleting history genuinely resets it.
function M.retired_actions(history_text, opts)
  opts = opts or {}
  local limit = opts.limit or M.RETIRE_AFTER_SKIPS
  local skips = {}
  for _, a in ipairs(M.parse_history(history_text)) do
    if a.outcome == "skipped" and a.description then
      skips[a.description] = (skips[a.description] or 0) + 1
    end
  end
  local out = {}
  for description, n in pairs(skips) do
    if n >= limit then out[description] = n end
  end
  return out
end

-- How many times this action has been skipped, for the screen that has to say
-- "and that is the second time" at the moment it happens.
function M.skip_count(history_text, description)
  local n = 0
  for _, a in ipairs(M.parse_history(history_text)) do
    if a.outcome == "skipped" and a.description == description then n = n + 1 end
  end
  return n
end

-- Descriptions the player has ever got wrong. `Cache Hit` is awarded for
-- recalling one of these, which is the moment the training actually worked.
function M.previously_missed(history_text)
  local out = {}
  for _, a in ipairs(M.parse_history(history_text)) do
    if a.outcome ~= "correct" and a.outcome ~= "skipped" then out[a.description] = true end
  end
  return out
end

-- Best average on a course so far, or nil if it has never been finished. Only
-- completed runs count: a retired stage's average is over whatever happened to
-- be answered before walking away, which is not a time to beat.
function M.best_course_average(history_text, course)
  local best
  for _, st in ipairs(M.parse_stages(history_text)) do
    if st.course == course and st.completed == true and type(st.average_ms) == "number" then
      if best == nil or st.average_ms < best then best = st.average_ms end
    end
  end
  return best
end

-- The block that follows `"<key>":`, brace- and bracket-balanced and
-- string-aware. Returns the inner text, without the delimiters.
local function block_after(text, key, open, close)
  local _, at = text:find('"' .. key .. '"%s*:%s*%' .. open)
  if not at then return nil end
  local depth, i = 1, at + 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == '"' then
      local _, nxt = read_string(text, i)
      i = nxt
    else
      if c == open then depth = depth + 1
      elseif c == close then
        depth = depth - 1
        if depth == 0 then return text:sub(at + 1, i - 1) end
      end
      i = i + 1
    end
  end
  return nil
end

-- The Cabinet's state, as JSON a human can read and delete. Trophy RULES live in
-- trophies.lua, which is deliberately dependency-free; the JSON lives here,
-- because this file already owns the one reader and writer in the project and a
-- second pair would be the drift everything else here avoids.
function M.serialize_cabinet(cabinet)
  cabinet = cabinet or {}
  local function flat(tbl, numeric)
    local keys = {}
    for k in pairs(tbl or {}) do keys[#keys + 1] = k end
    table.sort(keys)  -- deterministic, so the file diffs cleanly
    local parts = {}
    for _, k in ipairs(keys) do
      local v = tbl[k]
      parts[#parts + 1] = jstr(k) .. ":" .. (numeric and jnum(v) or jstr(v))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  local days = {}
  for _, d in ipairs(cabinet.days or {}) do days[#days + 1] = jstr(d) end
  return table.concat({
    "{\n  ", jstr("counts"), ": ", flat(cabinet.counts, true),
    ",\n  ", jstr("earned"), ": ", flat(cabinet.earned, false),
    ",\n  ", jstr("days"), ": [", table.concat(days, ","), "]",
    "\n}\n",
  })
end

function M.parse_cabinet(text)
  text = tostring(text or "")
  local cabinet = { counts = {}, earned = {}, days = {} }
  local counts = block_after(text, "counts", "{", "}")
  if counts then
    for k, v in pairs(read_pairs("{" .. counts .. "}")) do
      if type(v) == "number" then cabinet.counts[k] = v end
    end
  end
  local earned = block_after(text, "earned", "{", "}")
  if earned then
    for k, v in pairs(read_pairs("{" .. earned .. "}")) do
      -- A null day is legitimate: a trophy earned before days were recorded.
      cabinet.earned[k] = (v ~= nil) and tostring(v) or ""
    end
  end
  local days = block_after(text, "days", "[", "]")
  if days then
    local i = 1
    while i <= #days do
      if days:sub(i, i) == '"' then
        local v, nxt = read_string(days, i)
        cabinet.days[#cabinet.days + 1] = v
        i = nxt
      else
        i = i + 1
      end
    end
    table.sort(cabinet.days)
  end
  return cabinet
end

-- A general JSON encoder, for the state document QML consumes.
--
-- history.jsonl is hand-built field by field because its shape is fixed and
-- writing it that way is the cheapest correct thing. The screen state is not
-- fixed. It differs per screen and will keep changing as the display grows,
-- so it gets a real encoder instead of a dozen more bespoke concatenations.
--
-- Object keys are SORTED. The state file is written many times a second and
-- read by a file watcher; stable key order means a screen that has not changed
-- produces an identical file, which makes it diffable, testable, and cheap for
-- a watcher to ignore.
local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end

function M.to_json(value)
  local t = type(value)
  if value == nil then return "null" end
  if t == "boolean" then return value and "true" or "false" end
  if t == "number" then
    -- Integers without a trailing .0, because these are read by humans too.
    if value ~= value or value == math.huge or value == -math.huge then return "null" end
    if math.floor(value) == value then return string.format("%d", value) end
    return string.format("%.4g", value)
  end
  if t == "string" then return jstr(value) end
  if t ~= "table" then return "null" end

  if is_array(value) then
    local parts = {}
    for i = 1, #value do parts[i] = M.to_json(value[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end

  local keys = {}
  for k in pairs(value) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = jstr(k) .. ":" .. M.to_json(value[k])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- One JSON object per stage, for appending to history.jsonl. Per-answer detail
-- is included so Blind Spots can later mine which bindings you actually miss.
function M.history_record(state, meta)
  meta = meta or {}
  local s = M.summary(state)
  local parts = {}
  for _, r in ipairs(state.results) do
    parts[#parts + 1] = table.concat({
      "{", jstr("combo"), ":", jstr(r.expected),
      ",", jstr("description"), ":", jstr(r.description),
      ",", jstr("outcome"), ":", jstr(r.outcome),
      ",", jstr("pressed"), ":", jstr(r.combo),
      ",", jstr("reaction_ms"), ":", jnum(r.reaction_ms),
      "}",
    })
  end
  return table.concat({
    "{", jstr("stamp"), ":", jstr(meta.stamp or ""),
    ",", jstr("course"), ":", jstr(state.course or "all"),
    -- Which ladder the score was earned on. Without it a 9/10 on easy and a
    -- 6/10 on hard are not comparable, and every cross-run number -- averages,
    -- personal bests, the ghost -- would quietly mix them.
    ",", jstr("difficulty"), ":", jstr(state.difficulty or M.DEFAULT_DIFFICULTY),
    ",", jstr("prompts"), ":", jnum(s.prompts),
    ",", jstr("base_prompts"), ":", jnum(s.base_prompts),
    ",", jstr("requeues"), ":", jnum(s.requeues),
    ",", jstr("away"), ":", jnum(s.away),
    ",", jstr("correct"), ":", jnum(s.correct),
    ",", jstr("offs"), ":", jnum(s.offs),
    ",", jstr("points"), ":", jnum(s.points),
    ",", jstr("average_ms"), ":", jnum(s.average_ms and math.floor(s.average_ms) or nil),
    ",", jstr("assisted"), ":", jbool(state.assisted),
    ",", jstr("completed"), ":", jbool(state.finished),
    ",", jstr("clean"), ":", jbool(s.clean and not state.assisted),
    ",", jstr("answers"), ":[", table.concat(parts, ","), "]",
    "}",
  })
end

return M

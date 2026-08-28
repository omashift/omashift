-- Omashift engine: the thin layer that connects core.lua to Hyprland.
--
-- Everything here needs `hl.*`; everything testable lives in core.lua. Loaded
-- transiently with `hyprctl eval "dofile(...)"`, so `hyprctl reload` is a
-- complete uninstall. There is no config to edit and nothing to clean up.
--
-- Architecture, per the Phase 1 spike:
--   * hl.bind accepts a plain Lua FUNCTION, so every candidate combo binds to a
--     closure inside the game submap and Hyprland does all combo matching. No
--     keycode or XKB tables, and a wrong-but-known answer identifies itself.
--   * hl.on("input.keyboard.key") gives a millisecond timestamp per event; that
--     is the clock. Events arrive duplicated, which costs nothing here: the
--     timestamp write is idempotent, and the wheels repaint only when the held
--     modifiers actually change. An explicit (keycode, timestamp) dedupe used to
--     live in core and was deleted once that comparison made it redundant.
--   * The submap suppresses every real binding, so "Close window" cannot close
--     the game.

local BASE = os.getenv("OMASHIFT_BASE") or (os.getenv("HOME") .. "/.local/share/omashift")
local STATE = os.getenv("OMASHIFT_STATE") or "/tmp/omashift-state.txt"
-- The same screen, structured. The terminal display reads STATE; a Quickshell
-- overlay reads this. Written ALONGSIDE the text rather than replacing it, so
-- the working display is untouched while the QML one is built against it.
local STATE_JSON = os.getenv("OMASHIFT_STATE_JSON") or "/tmp/omashift-state.json"

package.path = BASE .. "/lib/?.lua;" .. package.path
local core = dofile(BASE .. "/lib/core.lua")
-- Screens are a pure function of the model. See lib/screens.lua for the rule
-- that keeps them that way.
local screens = dofile(BASE .. "/lib/screens.lua")
local trophies = dofile(BASE .. "/lib/trophies.lua")
local inventory = dofile(BASE .. "/lib/inventory.lua")

-- The chord that launches the game, shown on the ready screen. It lives here
-- because this file is what the keybinding invokes; the renderer has no way to
-- know it. Change it here if the binding in bindings.lua changes.
local LAUNCH_KEY = "SUPER + ALT + O"

-- The way out of a stage, and the ONE string that both binds it and shows it.
-- Two copies would be worse than none: a hint that names a chord nothing is
-- bound to is how a player ends up trapped while reading the instructions.
local RETIRE_KEY = "SUPER + SHIFT + ESCAPE"

-- Give up on ONE note, rather than on the stage.
--
-- A keymap can contain a binding this keyboard cannot produce. A laptop with no
-- PrintScreen key has three, and before this existed the note was unanswerable,
-- missing it requeued it, and the only way out of the loop was to wait out the
-- idle release. Same family as the retire chord on purpose: ESCAPE gets you
-- out, and the modifier says out of what.
--
-- CHOSEN AGAINST THE PLAYER'S OWN KEYMAP, not hardcoded. Every candidate here
-- is free on the machine this was written on, and none of them is guaranteed
-- free on anyone else's. A skip chord that shadows a real binding would make
-- that binding untestable, which is a strange way to repay someone for
-- installing a keybinding trainer.
local SKIP_CANDIDATES = {
  "SUPER + CTRL + ESCAPE",
  "SUPER + CTRL + SHIFT + ESCAPE",
  "SUPER + ALT + SHIFT + ESCAPE",
}

local SUBMAP = "omashift"

-- The first candidate nothing else claims. Nil if the keymap has taken all of
-- them, in which case the game says so rather than shadowing a binding: the
-- screen prints whatever this is, so "no skip key" is visible instead of a
-- chord that silently does something else.
local function pick_skip_key(bank)
  local taken = {}
  for _, entry in ipairs(bank or {}) do taken[entry.combo] = true end
  for _, chord in ipairs(SKIP_CANDIDATES) do
    if not taken[chord] and chord ~= RETIRE_KEY then return chord end
  end
  return nil
end

local SKIP_KEY = pick_skip_key(inventory)

-- Re-loading replaces the previous run rather than stacking handlers.
_G.omashift_generation = (_G.omashift_generation or 0) + 1
local generation = _G.omashift_generation

-- hl.define_submap ACCUMULATES bindings, and hl.unbind() reports success but
-- does not actually remove submap-scoped ones. 29 reloads produced 5,687 submap
-- binds and 58 panic-exit handlers, each of which persisted the stage. One run
-- wrote six identical history records.
--
-- So the submap is defined EXACTLY ONCE per Hyprland session, and every closure
-- dispatches through a global that each reload replaces. Reloading swaps the
-- logic without touching the binding table.

local stage = nil
local last_timestamp = 0
-- What prior play looked like when this stage was ARMED. Trophies that mean
-- "previously" have to be judged against it, not against the file that now
-- contains this very run.
--
-- Held as parsed FACTS, not as text. Parsing on completion blew Hyprland's
-- per-callback time budget once the history grew past a couple of dozen
-- stages, and the callback was killed before the results screen could be
-- published, so a finished stage left the overlay stuck on the last answer.
local prior_facts = nil

-- Spaced repetition state, persisted across sessions. Absolute day number is
-- computed once per load: core never reads a clock, so the caller supplies it.
local SCHEDULE_FILE = BASE .. "/schedule.lua"
local HISTORY_FILE = BASE .. "/history.jsonl"
local CONFIG_DIR = os.getenv("XDG_CONFIG_HOME") or ((os.getenv("HOME") or "") .. "/.config")
-- The Cabinet lives in STATE, not DATA: it is generated from play and safe to
-- delete, which is Omarchy's own convention and the stance the design takes.
local STATE_DIR = os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state")
local CABINET_FILE = STATE_DIR .. "/omashift/trophies.json"
local COURSES_FILE = CONFIG_DIR .. "/omashift/courses.lua"
local SECONDS_PER_DAY = 86400
local today = math.floor(os.time() / SECONDS_PER_DAY)
local schedule = {}
do
  local f = io.open(SCHEDULE_FILE, "r")
  if f then
    f:close()
    local okr, loaded = pcall(dofile, SCHEDULE_FILE)
    if okr and type(loaded) == "table" then schedule = loaded end
  end
end

-- Whole file as text; core.parse_history does the reading. Absent or
-- unreadable is normal -- a first-ever run has no history -- and yields "".
local function read_history()
  local f = io.open(HISTORY_FILE, "r")
  if not f then return "" end
  local text = f:read("*a")
  f:close()
  return text or ""
end

-- User-defined courses, merged over the built-ins. The shipped tiers are one
-- person's judgment and a newcomer cannot see what is missing from them, so
-- this is the escape hatch.
--
-- Wrapped in pcall at every step: a syntax error in a hand-edited config file
-- must cost the player their custom courses, not their game.
-- The loader is shared with `omashift --courses` and `--cycle-course`, so a
-- course this engine can play is a course the menu can reach. See
-- lib/courses-file.lua for the bug that cost.
do
  local added, problems = require("courses-file").merge(core, COURSES_FILE)
  _G.omashift_courses_added = added
  _G.omashift_course_problems = problems
end

local function read_cabinet()
  local f = io.open(CABINET_FILE, "r")
  if not f then return trophies.new_cabinet() end
  local text = f:read("*a")
  f:close()
  local ok, cab = pcall(core.parse_cabinet, text or "")
  -- A hand-edited or truncated cabinet must not cost the player their session.
  -- They lose the trophies they can win back, not the game.
  return (ok and cab) or trophies.new_cabinet()
end

local function write_cabinet(cabinet)
  os.execute(("mkdir -p %q"):format(STATE_DIR .. "/omashift"))
  local f = io.open(CABINET_FILE, "w")
  if not f then return end
  f:write(core.serialize_cabinet(cabinet))
  f:close()
end

local function save_schedule()
  local f = io.open(SCHEDULE_FILE, "w")
  if not f then return end
  f:write(core.serialize_schedule(schedule))
  f:close()
end

-- Was the co-driver called for the CURRENT prompt? Per-prompt, not per-stage:
-- an assisted answer must grade HARD even if the rest of the stage was clean,
-- or the co-driver becomes a free answer key.
local prompt_assisted = false
local by_combo = {}
for _, e in ipairs(inventory) do by_combo[e.combo] = e end

-- ---------------------------------------------------------------------------
-- Display: one JSON document for the overlay, and the same screen as text.
--
-- The text is NOT vestigial, which is a mistake I made and the suite caught.
-- The terminal renderer that once read /tmp/omashift-state.txt is gone, so it
-- looks like a leftover, but the offline tests read exactly that file: it is
-- how `test/fixtures/screens/*.txt` is captured and compared, and it is the
-- only way this project can assert what a screen SAYS rather than what it
-- carries. Deleting the write left twelve assertions with nothing to read.
--
-- The spike's finding is why swapping the display cost nothing in the first
-- place: capture happens in Lua, so the surface is replaceable without touching
-- game logic.
-- ---------------------------------------------------------------------------
-- Monotonic milliseconds. Hyprland's key-event timestamps are on a DIFFERENT
-- timebase from /proc/uptime (observed 32,632,554 vs 782,876,570), so the two
-- cannot be mixed. Both ends of a reaction measurement read this one.
-- THE CLOCK AND THE TIMERS MUST AGREE.
--
-- Every deferral in this file goes through `hl.timer`, so whoever owns the
-- timers owns the passage of time. Reading the clock from somewhere else meant
-- the two could disagree, and under test they did: virtual timers advanced
-- instantly while /proc/uptime crawled, so a reaction time was however long the
-- harness happened to take. Fast machine, 250 km/h; busy machine, 0. The screen
-- goldens captured whichever it did that second and the suite flaked.
--
-- Hyprland provides no clock, so in real play this falls through to
-- /proc/uptime exactly as before. Nothing about a played stage changes.
local function now_ms()
  if type(hl.now_ms) == "function" then return hl.now_ms() end
  local f = io.open("/proc/uptime", "r")
  if not f then return 0 end
  local line = f:read("*l")
  f:close()
  local secs = tonumber((line or ""):match("^(%S+)")) or 0
  return math.floor(secs * 1000)
end

-- Live modifier state. hl.is_key_down is authoritative, so no key tracking of
-- our own. The spike confirmed it works and it handles remapped modifiers.
local function held_modifiers()
  return {
    SUPER = hl.is_key_down("Super_L") or hl.is_key_down("Super_R"),
    CTRL  = hl.is_key_down("Control_L") or hl.is_key_down("Control_R"),
    ALT   = hl.is_key_down("Alt_L") or hl.is_key_down("Alt_R"),
    SHIFT = hl.is_key_down("Shift_L") or hl.is_key_down("Shift_R"),
  }
end

-- The last screen drawn, so a modifier change can redraw it without the caller
-- having to know what was on it.
local repaint = nil

-- Seconds until the idle release fires, once it is close enough to be worth
-- saying. Nil the rest of the time: a clock that runs from the first second of
-- every note would be a countdown to nothing, on screen constantly.
local idle_remaining_s = nil
local idle_generation = 0

-- A key was pressed that this stage has nothing to do with.
--
-- WHY THE GAME HAS TO SAY SOMETHING. A submap replaces the whole keymap while a
-- stage runs, so a key outside the question bank is not merely wrong, it is
-- swallowed: no answer, no off, no reaction of any kind. A player pressing
-- PrintScreen on its own got exactly nothing back, which is indistinguishable
-- from a hung game and is a strange thing for a game about pressing keys to do.
--
-- IT DOES NOT SAY "NOT BOUND TO ANYTHING", which is what it said first and is
-- usually false. PrintScreen on that machine IS bound, to a screenshot; it is
-- simply not one of the questions, and the game has taken the keyboard away
-- from it. Blaming the player\'s keymap for the game\'s own capture is a
-- confident, wrong explanation, which is worse than the silence it replaced.
--
-- It is NOT an off. You did not name the wrong action, you pressed something
-- that names no action at all, and scoring that would teach nothing.
local unbound = false
local unbound_generation = 0

-- How long to wait for the submap to land an answer before deciding that
-- nothing was bound to the key.
--
-- THIS IS A RACE, AND THE WINDOW IS THE ONLY THING THAT DECIDES IT. The raw key
-- event and the submap's bind are two separate deliveries, and nothing
-- guarantees their order or their spacing. Too short and a slow dispatch under
-- load reads a perfectly good answer as a key bound to nothing.
--
-- 350ms rather than the 250ms this started at, because 250 is exactly the
-- budget Hyprland gives a guarded call, and this project has already had one
-- callback killed for exceeding it. Picking the same number as the thing most
-- likely to delay us is asking for the race to be lost.
--
-- The consequence of losing it anyway is bounded: an answer replaces the whole
-- screen with a result, so the worst case is a flash of the notice rather than
-- a wrong scoreline. That asymmetry is why waiting longer is the safe side.
local UNBOUND_AFTER_MS = 350

-- How long the notice stays up once shown. It is about the last thing you
-- pressed, and a warning that outlives its subject becomes part of the screen.
local UNBOUND_CLEAR_MS = 1600
-- Which keycodes are physically down, so an auto-repeat is not read as a new
-- press. Without it, holding SUPER for half a second repeats the keycode, the
-- modifier set does not change because it was already held, and the game would
-- announce "not one of your bindings" in the middle of a chord being typed.
local keys_down = {}

-- WRITE THEN RENAME, never write in place.
--
-- A reader that lands mid-write sees a truncated file. For the text screen that
-- was one ugly frame; for the JSON the overlay parses it is a parse failure, and
-- the overlay treats a parse failure as "no game" and goes blank. That was
-- written down as a hazard during the render/publish merge and then dismissed as
-- moot on the grounds that the display read text -- which was wrong even then,
-- because the overlay has always parsed JSON.
--
-- It surfaced the moment menu keys started depending on the parsed screen:
-- cycling the course rewrites this file, and a keypress landing in that window
-- found no screen at all. rename(2) is atomic on the same filesystem, so a
-- reader sees either the old file or the new one and never a half of either.
local function write_atomic(path, text)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end
  f:write(text)
  f:close()
  os.rename(tmp, path)
end

local function render(lines)
  write_atomic(STATE, table.concat(lines, "\n") .. "\n")
end

-- Wrapped in pcall because a display is presentation: a serializer fault must
-- never take down a stage in progress, and the text half carries on regardless.
--
-- But it must SAY SO. Returning silently meant a screen that failed to publish
-- left the overlay showing the previous one forever, with nothing anywhere to
-- explain why, which is exactly how a completed stage left the results page
-- stuck on the last answer.
local function publish(model)
  local ok, text = pcall(core.to_json, model)
  if not ok then
    local log = io.open(BASE .. "/publish.log", "a")
    if log then
      log:write(os.date("%H:%M:%S"), "  serialize failed for screen=",
                tostring(model and model.screen), ": ", tostring(text), "\n")
      log:close()
    end
    return
  end
  write_atomic(STATE_JSON, text .. "\n")
end

-- ONE call draws a screen. It used to take two: a `render` block of text for the
-- terminal display and a `publish` block of structured state for the overlay,
-- hand-kept in sync across ten and nine call sites respectively, in this file.
--
-- The model is now the only source. The text is derived from it, so the two
-- halves cannot describe different screens no matter which display you are
-- running. If a screen needs a fact, put the fact in the model.
-- Every screen write resets the watchdog. A healthy game draws constantly:
-- prompts, results, countdowns, and a repaint on every modifier change. Silence
-- here is the most reliable signal that nothing is driving the game any more.
--
-- COUNTED IN TICKS, not milliseconds off a clock. The watchdog's own timer chain
-- is the measure, which means it cannot be fooled by a wall clock that jumps
-- across a suspend, and it needs no clock seam to be testable.
local quiet_ticks = 0

local function show(model)
  quiet_ticks = 0
  publish(model)
  render(screens.render(model))
end

-- Where Omarchy keeps its themes. User first, because a theme installed by hand
-- should win over one that shipped with the same name.
-- Resolve a course's backdrop to a path that actually exists.
--
-- The resolution itself lives in lib/scene.lua, because the Cabinet and the
-- Logbook publish backdrops too and a copy of this in each of them is three
-- chances to disagree about where Omarchy keeps its wallpapers.
local scene_lib = require("scene")

local function scene_for(course)
  return scene_lib.resolve(core.scene_for(course))
end

-- The block every in-play screen carries, so a consumer can render the HUD
-- without caring which screen it is looking at.
local function stage_model()
  if not stage then return nil end
  return {
    index = stage.index,
    total = #stage.prompts,
    base_total = stage.base_length,
    gear = stage.gear,
    max_gear = core.MAX_GEAR,
    points = stage.points,
    streak = stage.streak,
    assisted = stage.assisted == true,
    course = stage.course,
    difficulty = stage.difficulty or core.DEFAULT_DIFFICULTY,
    -- The course's backdrop travels with the stage, so every in-play screen gets
    -- it without each publish site having to remember.
    scene = scene_for(stage.course),
  }
end

local show_prompt
-- Redraw the current pace note when the modifier set changes.
local function arm_repaint(prompt, hint)
  repaint = function() show_prompt(prompt, hint) end
end

function show_prompt(prompt, hint)
  arm_repaint(prompt, hint)
  local held = held_modifiers()
  show {
    screen = "prompt",
    stage = stage_model(),
    prompt = { description = prompt.description, alts = prompt.alts },
    -- The hint's LEVEL matters as much as its text: a display can style
    -- "modifiers revealed" differently from "the whole combo given away".
    hint = hint and { level = hint.level, text = hint.text } or nil,
    held = held,
    quattro = core.full_quattro(held),
    -- The only screen that carries them, because it is the only screen where
    -- they WORK. Once the stage ends the submap is reset and these chords do
    -- nothing, so advertising them there would be a lie.
    retire_key = RETIRE_KEY,
    skip_key = SKIP_KEY,
    -- Seconds until the keyboard comes back on its own, or nil when that is
    -- far enough away to be noise. A player who cannot answer the note in front
    -- of them needs to know that waiting is a real option and how long it
    -- takes; without it, the only honest reading of a stuck screen is that the
    -- machine has hung.
    release_in_s = idle_remaining_s,
    -- The last thing pressed matched nothing in your keymap. Not an off: you
    -- did not name the wrong action, you pressed a key that names no action.
    unbound = unbound or nil,
  }
end

-- The co-driver calls the note if you wait. Polls while a prompt is open;
-- a called stage still trains and still scores, but is marked assisted so it
-- cannot set a personal best.
local codriver_generation = 0
local function start_codriver(prompt)
  codriver_generation = codriver_generation + 1
  local mine = codriver_generation
  local elapsed = 0
  local function tick()
    if mine ~= codriver_generation then return end
    if generation ~= _G.omashift_generation then return end
    if not stage or stage.finished then return end
    elapsed = elapsed + 500
    local hint = core.hint_for(prompt, elapsed, stage.codriver)
    if hint then
      prompt_assisted = true
      show_prompt(prompt, hint)
    end
    if not hint or hint.level ~= "full" then
      hl.timer(tick, { timeout = 500, type = "oneshot" })
    end
  end
  hl.timer(tick, { timeout = 500, type = "oneshot" })
end

local function show_result(result)
  -- Alternates are worth teaching rather than hiding: "there are two ways to do
  -- this" is a real thing to learn about your own keymap.
  local cur = core.current(stage)
  show {
    screen = "result",
    stage = stage_model(),
    result = {
      outcome = result.outcome,
      -- The tier NAME, not a blanket "CLEAN". The old fallback printed CLEAN for
      -- every tier without a praise phrase, so the slowest possible answer came
      -- back reading CLEAN, and it collided with the real tier of that name.
      -- In a game about reaction time, feedback that flatters the bottom tier
      -- points the player the wrong way.
      tier = result.tier,
      praise = result.praise,
      speed_kmh = core.speed_kmh(result.reaction_ms),
      points = result.points,
      expected = result.expected,
      description = result.description,
      pressed = (result.outcome ~= "correct") and result.combo or nil,
      pressed_was = result.pressed_was,
      alts = cur and cur.alts or nil,
      ghost_kmh = result.ghost_ms and core.speed_kmh(result.ghost_ms) or nil,
      -- Gaps in SECONDS, the racing idiom, matching what the screens show.
      ghost_gap_s = result.ghost_delta and (result.ghost_delta / 1000) or nil,
      best = result.best == true,
    },
  }
end

-- Post-stage telemetry: splits by category, then every answer. A stage total
-- says you were slow; a split says WHICH KIND of thing you were slow at, which
-- is the whole point of measuring.
-- ONE end-of-stage page.
--
-- The summary used to show for 3.5s and then be replaced by telemetry, which
-- meant the numbers you most wanted to sit with were the ones that vanished.
-- Advancing on a keypress is not available here: hand_back() has already
-- released the submap by this point, so the engine cannot see a key, and having
-- the display read the tty again would drag back every problem the start gate
-- took three attempts to solve. One page, no timer, nothing to miss.
--
-- Milliseconds are gone throughout. Speed is the reading; the only times left
-- are GAPS to the ghost, in seconds, which is how motorsport has always
-- expressed them.
local function show_results()
  save_schedule()
  local s = core.summary(stage)
  local tiers = core.tier_counts(stage)
  local splits = core.splits(stage)

  local notes = {}
  for i, r in ipairs(stage.results) do
    notes[i] = {
      outcome = r.outcome,
      description = r.description,
      speed_kmh = (r.outcome == "correct") and core.speed_kmh(r.reaction_ms) or 0,
      tier = r.tier,
      expected = r.expected,
      pressed = (r.outcome ~= "correct") and r.combo or nil,
      pressed_was = r.pressed_was,
    }
  end
  local ladder = {}
  for i, t in ipairs(tiers) do
    ladder[i] = { name = t.name, count = t.count, share = t.share }
  end
  local split_rows = {}
  for i, sp in ipairs(splits) do
    split_rows[i] = {
      name = sp.name, correct = sp.correct, asked = sp.asked, offs = sp.offs,
      speed_kmh = sp.average_ms and core.speed_kmh(sp.average_ms) or nil,
    }
  end
  local won = {}
  for i, t in ipairs(stage.trophies or {}) do
    won[i] = { phrase = t.phrase, tier = t.tier, class = t.class }
  end

  show {
    screen = "results",
    stage = stage_model(),
    -- ESCAPE GOES BACK TO THE MENU, not out of the app. Finishing a stage and
    -- wanting another go is the ordinary case, and the only way to act on it
    -- was to close the game and reach for the launch chord again. The overlay
    -- already knows what to do with this: the Cabinet and the Logbook have used
    -- it since they existed.
    --
    -- The 30 second timeout still LEAVES, deliberately. Returning to a menu
    -- that holds the keyboard, on a machine somebody has walked away from, is
    -- the opposite of what the timeout is for.
    back = "menu",
    summary = {
      correct = s.correct, prompts = s.prompts, offs = s.offs, points = s.points,
      requeues = s.requeues, away = s.away,
      clean = s.clean == true, assisted = stage.assisted == true,
      average_kmh = s.average_kmh, top_kmh = s.top_kmh,
      ghost_gap_s = s.ghost_delta and (s.ghost_delta / 1000) or nil,
      ghost_notes = s.ghost_notes, ghost_beat = s.ghost_beat,
    },
    ladder = ladder,
    splits = split_rows,
    notes = notes,
    trophies = won,
  }
end

-- ---------------------------------------------------------------------------
-- Stage flow
-- ---------------------------------------------------------------------------
-- Append one JSON line per stage. Called on BOTH completion and retire: a
-- partial run carries the signal spaced repetition and Blind Spots consume.
local function persist()
  if generation ~= _G.omashift_generation then return end
  if not stage or #stage.results == 0 then return end
  -- A completed stage is persisted by advance(); retiring afterwards must not
  -- write it a second time.
  if stage.persisted then return end
  stage.persisted = true
  local ok, line = pcall(core.history_record, stage,
    { stamp = os.date("%Y-%m-%dT%H:%M:%S") })
  if not ok then return end
  local f = io.open(HISTORY_FILE, "a")
  if not f then return end
  f:write(line .. "\n")
  f:close()

  -- The Cabinet is evaluated against the history as it stood BEFORE this stage,
  -- which is why it runs after the write but reads its context from what was
  -- there first. "Recalling a binding you previously missed" would otherwise be
  -- satisfied by the miss in this very run.
  local facts = prior_facts or { previously_missed = {}, course_best = {} }
  local okc, won = pcall(function()
    local cabinet = read_cabinet()
    local list = trophies.record(cabinet, {
      course      = stage.course,
      completed   = stage.finished == true,
      assisted    = stage.assisted == true,
      difficulty  = stage.difficulty,
      day         = os.date("%Y-%m-%d"),
      summary     = core.summary(stage),
      results     = stage.results,
      -- Precomputed at arm time. Re-deriving these here is what killed the
      -- callback, and they describe the history BEFORE this stage anyway.
      previously_missed       = facts.previously_missed,
      previous_course_average = facts.course_best[stage.course],
      -- The secret trophy is judged on the whole case, and "every mastery on
      -- every course" needs to know what the courses are. Without this it can
      -- never unlock, and it would never say why.
      courses     = core.course_names(),
    })
    write_cabinet(cabinet)
    return list
  end)
  stage.trophies = okc and won or {}
end

-- True between an answer landing and the next pace note appearing. Without it a
-- keypress during the ~900ms result pause answers the SAME prompt again, which
-- is how a 6-prompt stage came back reporting "6 / 7".
-- Declared BEFORE advance() so both it and handle() close over the same local.
local settling = false

-- Give the desktop back. Every exit from game mode goes through here, because
-- the two halves used to disagree: retiring reset the submap but left the hint
-- overlay off for good, and completing a stage did neither -- the player sat on
-- a summary screen with every binding suppressed and nothing left to answer.
--
-- Deliberately does NOT clear `stage`: the telemetry screen renders 3.5s later
-- and still needs it. Safe to call twice; the overlay restore is idempotent.
local function hand_back()
  -- EVERYTHING THAT CAN STILL DRAW A PROMPT HAS TO STOP FIRST.
  --
  -- `repaint` was cleared when an answer landed and nowhere else, so after an
  -- idle release the key listener still held a closure over the last pace note.
  -- The next modifier press redrew it, and by then `stage` was nil: a prompt
  -- screen with no stage behind it, reading "0 / 0", showing the note the
  -- player had just escaped and offering a retire chord that no longer worked.
  -- It looked like the game had thrown them back to the start of a loop.
  repaint = nil
  codriver_generation = codriver_generation + 1
  idle_generation = idle_generation + 1
  idle_remaining_s = nil
  unbound_generation = unbound_generation + 1
  unbound = false
  keys_down = {}

  hl.dispatch(hl.dsp.submap("reset"))
  hl.exec_cmd(BASE .. "/omashift-guide-restore")
end

-- The dead-man's switch assumes the player is still there to press it. This is
-- the one for when they are not. A prompt left unanswered this long means they
-- walked away, and holding their entire keymap hostage until they come back is
-- the worst thing the game can do to a desktop.
--
-- Per-prompt, not global: a new prompt supersedes the previous watch, so "idle"
-- means "this prompt went unanswered", which is exactly when the player is gone.
-- Generous on purpose -- the co-driver has already given up at 8s, so anything
-- past a minute is absence, not thought.
-- The default. Overridable per launch like the co-driver thresholds, because
-- this is a feel decision too: how long "away" is depends on the player.
-- How long the submap is held after a stage ENDS, before the keymap comes back.
--
-- THERE IS A GAP BETWEEN THE TWO, AND A KEYPRESS CAN FALL INTO IT. The results
-- page holds exclusive keyboard focus, which swallows Hyprland's own shortcuts,
-- but the compositor grants that focus asynchronously after the surface maps.
-- Handing the keymap back at the same instant leaves a frame or two where the
-- real bindings are live and nothing is catching them.
--
-- That is not hypothetical. A player finishing a Track Day stage had pressed
-- SUPER + SHIFT + 3 three times trying to answer a note; all three were caught
-- and scored as offs. The stage ended on the third. The same reflex a moment
-- later landed on a live keymap, and "Move window to workspace 3" did exactly
-- what it says.
--
-- Four hundred milliseconds is far longer than a focus grant and nothing at all
-- against the ninety second watchdog that backstops it.
local HANDBACK_GRACE_MS = 400

local IDLE_RELEASE_DEFAULT_MS = 60000

-- How long before the release the clock appears. Long enough that a player who
-- is stuck sees it well before it matters, short enough that a player who is
-- thinking is not being hurried by a timer.
local COUNTDOWN_FROM_MS = 30000
local idle_release_ms = IDLE_RELEASE_DEFAULT_MS

local function start_idle_watch()
  -- Zero (or negative) disables the watch outright: the player keeps the
  -- keyboard until they retire. An explicit opt-out, not an accident -- the
  -- launcher passes "" for unconfigured, which never reaches here as 0.
  if idle_release_ms <= 0 then return end
  idle_generation = idle_generation + 1
  local mine = idle_generation
  local elapsed = 0
  idle_remaining_s = nil
  -- One second steps once the clock is showing, five before that. A countdown
  -- that jumps five at a time reads as broken, and ticking every second for a
  -- minute is work nobody is watching.
  local function tick(step)
    if mine ~= idle_generation then return end
    if generation ~= _G.omashift_generation then return end
    if not stage or stage.finished then return end
    elapsed = elapsed + step
    local left = idle_release_ms - elapsed
    if left > 0 then
      local showing = left <= COUNTDOWN_FROM_MS
      local was = idle_remaining_s
      idle_remaining_s = showing and math.ceil(left / 1000) or nil
      -- Redraw only when the number changes. The prompt screen is republished
      -- on every modifier change already; adding a second per-second publish
      -- of an identical document is how a Lua timer budget gets spent.
      if idle_remaining_s ~= was and repaint then repaint() end
      hl.timer(function() tick(showing and 1000 or 5000) end,
               { timeout = showing and 1000 or 5000, type = "oneshot" })
      return
    end
    -- Same shape as a retire: a partial run still carries signal for scheduling
    -- and Blind Spots, so it is persisted rather than discarded.
    persist()
    local scene = scene_for(stage and stage.course)
    stage = nil
    show { screen = "released", reason = "idle",
           after_s = math.floor(idle_release_ms / 1000), scene = scene }
    hand_back()
  end
  hl.timer(function() tick(5000) end, { timeout = 5000, type = "oneshot" })
end

local function advance()
  local prompt = core.next_prompt(stage, now_ms())
  if not prompt then
    persist()
    show_results()
    -- After persist(), never before: handing back is the last thing to happen,
    -- so a failure here cannot cost the player their record.
    --
    -- And a beat after the results page, so the overlay has taken the keyboard
    -- before the real bindings come back. Only on this path: a retire is a
    -- deliberate press and an idle release means nobody is there, so neither
    -- has a hand poised over a chord.
    local finished = stage
    hl.timer(function()
      if generation ~= _G.omashift_generation then return end
      -- A new stage may have started in the meantime, since ENTER on the
      -- results page goes straight again. That stage owns the submap now and
      -- resetting it here would strand the player mid-countdown.
      if stage ~= finished then return end
      hand_back()
    end, { timeout = HANDBACK_GRACE_MS, type = "oneshot" })
    return
  end
  prompt_assisted = false
  settling = false
  unbound = false
  unbound_generation = unbound_generation + 1
  show_prompt(prompt, nil)
  start_codriver(prompt)
  start_idle_watch()
end

local function handle(combo)
  if generation ~= _G.omashift_generation then return end
  if not stage or stage.finished then return end
  if settling then return end
  local entry = by_combo[combo]
  local result = core.answer(stage, combo, now_ms(), entry and entry.description)
  -- Assistance only counts if the player was actually present. A hint that
  -- fired while they were away from the keyboard is an interruption, not help,
  -- and should not cost them the stage's clean run.
  if result.outcome == "no-prompt" then return end
  if prompt_assisted and (result.reaction_ms or 0) < core.AWAY_MS then
    stage.assisted = true
  end
  settling = true
  repaint = nil
  codriver_generation = codriver_generation + 1   -- silence the co-driver
  -- An answer landed, so whatever was pressed WAS bound. Cancel the pending
  -- "not one of your bindings" before it can contradict the result page.
  unbound_generation = unbound_generation + 1
  unbound = false

  -- Spaced repetition: grade from measured reaction time, never self-report.
  result.assisted = prompt_assisted
  local asked = result.expected
  schedule[asked] = core.schedule(
    schedule[asked] or core.new_item(asked), core.grade_for(result), today)

  -- A fresh miss returns later in THIS stage while it is still warm. The
  -- within-stage half of the two-timescale scheme.
  if result.outcome == "off" then
    local missed = by_combo[asked]
    -- No gap argument: core picks a random distance. A fixed one made the
    -- return trivially predictable, so you braced for it instead of recalling.
    if missed then core.requeue(stage, missed) end
  end

  show_result(result)
  -- Brief pause so the result is readable before the next pace note.
  hl.timer(advance, { timeout = 900, type = "oneshot" })
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

-- The clock. Every real key event carries a millisecond timestamp; bindings
-- fire separately, so the most recent timestamp is the answer's arrival time.
local last_held = ""

-- Registered EXACTLY ONCE per Hyprland session, like the submap above and for
-- the same reason.
--
-- The engine is re-loaded on every arm, and this listener had no guard, so each
-- load added another subscriber that Hyprland could never drop. A long session
-- of playing and testing accumulated dozens, every one of them invoked on every
-- keystroke. The generation check makes stale ones cheap, but it does not make
-- them go away, and unbounded growth of compositor-side callbacks is exactly
-- the shape of the binding leak that once reached 5,687 entries.
--
-- The live handler is reassigned through a global, so a reload still takes
-- effect: the subscription stays, its target is replaced.
_G.omashift_on_key = function(keycode, timestamp_ms, key_state)
  if generation ~= _G.omashift_generation then return end
  if key_state == 1 and type(timestamp_ms) == "number" then
    last_timestamp = timestamp_ms
  end

  local fresh = false
  if key_state == 1 then
    fresh = not keys_down[keycode]
    keys_down[keycode] = true
  elseif key_state == 0 then
    keys_down[keycode] = nil
  end

  -- The event fires BEFORE Hyprland updates its pressed-key set, so read the
  -- modifiers on the next loop turn. (Same reason keybinding-guide defers.)
  hl.timer(function()
    if generation ~= _G.omashift_generation then return end
    if not repaint then return end
    local h = held_modifiers()
    local sig = (h.SUPER and "S" or "") .. (h.CTRL and "C" or "")
             .. (h.ALT and "A" or "") .. (h.SHIFT and "H" or "")
    local moved = sig ~= last_held
    if moved then
      last_held = sig
      repaint()
    end

    -- A fresh press that did not change the modifier set is a real key, not a
    -- modifier. Give the submap a moment to land an answer on it; if nothing
    -- arrives, nothing was bound to it.
    if fresh and not moved and stage and not stage.finished and not settling then
      unbound_generation = unbound_generation + 1
      local mine = unbound_generation
      hl.timer(function()
        if generation ~= _G.omashift_generation then return end
        if mine ~= unbound_generation then return end
        if not stage or stage.finished or settling or not repaint then return end
        unbound = true
        repaint()
        -- Clears itself. A warning that stays on screen becomes part of the
        -- screen, and this one is about the last thing you pressed.
        hl.timer(function()
          if mine ~= unbound_generation then return end
          if not unbound then return end
          unbound = false
          if repaint then repaint() end
        end, { timeout = UNBOUND_CLEAR_MS, type = "oneshot" })
      end, { timeout = UNBOUND_AFTER_MS, type = "oneshot" })
    end
  end, { timeout = 1, type = "oneshot" })
end

-- ---------------------------------------------------------------------------
-- The watchdog: taking the keyboard is never allowed to be permanent
-- ---------------------------------------------------------------------------
--
-- THE SUBMAP MUST NEVER OUTLIVE THE GAME. A submap left engaged captures every
-- key on the machine, and the launch chord is itself in the question bank, so a
-- stuck submap answers the player's attempt to relaunch as a pace note. There is
-- no route to a terminal either, because SUPER+RETURN is a pace note too. The
-- player is locked out of every tool that could rescue them. That happened, and
-- it is why this exists.
--
-- The per-prompt idle release cannot cover it. It gives up the moment there is
-- no stage (`if not stage ... then return end`), which is exactly the state that
-- strands someone: submap held, no stage, nothing watching.
--
-- This watch is different in three ways that matter:
--   * it is registered ONCE PER SESSION and re-arms itself, so it survives every
--     engine reload rather than dying with the stage that started it
--   * it never looks at `stage`, because the dangerous state is the one where
--     there is no stage
--   * it asks the COMPOSITOR what submap is live, not the engine's own belief,
--     since a wedged engine's belief is the thing in question
--
-- It is a backstop, deliberately slower than the 60s idle release, so a normal
-- walk-away is handled by the normal path and this only ever fires when that
-- path failed to.
local WATCHDOG_MS = 90000
local WATCHDOG_TICK_MS = 5000

_G.omashift_on_watchdog = function()
  if hl.get_current_submap() ~= SUBMAP then
    quiet_ticks = 0
    return
  end
  quiet_ticks = quiet_ticks + 1
  if (quiet_ticks * WATCHDOG_TICK_MS) < WATCHDOG_MS then return end

  -- The one exemption, and it is narrow: a LIVE stage whose player explicitly
  -- turned the idle release off has chosen to hold the keyboard until they
  -- retire, and the config documents that. No stage, or a finished one, is never
  -- a choice -- it is the bug this watch exists for.
  if stage and not stage.finished and idle_release_ms <= 0 then return end

  if stage and not stage.finished then persist() end
  local scene = scene_for(stage and stage.course)
  stage = nil
  show { screen = "released", reason = "watchdog",
         after_s = math.floor(WATCHDOG_MS / 1000), scene = scene }
  hand_back()
end

if not _G.omashift_watchdog_bound then
  _G.omashift_watchdog_bound = true
  -- Through the global, never a captured local: this timer chain outlives every
  -- reload, so it must always reach the CURRENT engine. Same reason the key
  -- listener dispatches through a global.
  local function tick()
    if _G.omashift_on_watchdog then pcall(_G.omashift_on_watchdog) end
    hl.timer(tick, { timeout = WATCHDOG_TICK_MS, type = "oneshot" })
  end
  hl.timer(tick, { timeout = WATCHDOG_TICK_MS, type = "oneshot" })
end

if not _G.omashift_key_listener_bound then
  _G.omashift_key_listener_bound = true
  hl.on("input.keyboard.key", function(keycode, timestamp_ms, key_state)
    -- Through the global, never a captured local: this subscription outlives
    -- every reload, so it must always reach the CURRENT engine.
    if _G.omashift_on_key then _G.omashift_on_key(keycode, timestamp_ms, key_state) end
  end)
end

-- Reassigned on every load; the bindings below call through these.
_G.omashift_on_answer = function(combo) handle(combo) end
-- Give up on this note and move on. NOT scored, NOT requeued, and deliberately
-- not put through the scheduler: a skip is not evidence that the player has
-- forgotten anything, and grading it as a failure would make the game drill
-- the one binding it can never teach them.
_G.omashift_on_skip = function()
  if generation ~= _G.omashift_generation then return end
  if not stage or stage.finished or settling then return end
  local result = core.skip(stage)
  if result.outcome == "no-prompt" then return end

  -- NOTHING LEAVES YOUR ROTATION WITHOUT YOU BEING TOLD. This skip is the one
  -- that retires the action, so the result page says so at the moment it
  -- happens rather than leaving the player to notice an absence.
  --
  -- Counted from the record plus this one, because the record is written when
  -- the stage ends and this is the middle of it.
  local before = core.skip_count(read_history(), result.description)
  result.retired = (before + 1) >= core.RETIRE_AFTER_SKIPS or nil
  settling = true
  repaint = nil
  codriver_generation = codriver_generation + 1
  idle_generation = idle_generation + 1
  idle_remaining_s = nil
  show_result(result)
  hl.timer(advance, { timeout = 900, type = "oneshot" })
end

_G.omashift_on_retire = function()
  persist()
  local scene = scene_for(stage and stage.course)
  stage = nil
  show { screen = "released", reason = "retired", scene = scene }
  hand_back()
end

if not _G.omashift_submap_defined then
  _G.omashift_submap_defined = true
  hl.define_submap(SUBMAP, function()
    -- Panic exit and dead-man's switch: without it a crash mid-stage strands the
    -- user in a desktop with no keybindings. Persists before discarding, since a
    -- retired stage still carries signal for scheduling and Blind Spots.
    hl.bind(RETIRE_KEY, function() _G.omashift_on_retire() end)

    -- One note, not the stage. Bound inside the submap like everything else, so
    -- it exists only while a stage is running.
    if SKIP_KEY then
      hl.bind(SKIP_KEY, function() _G.omashift_on_skip() end)
    end

    -- One closure per candidate combo. Hyprland does the matching, so a wrong
    -- answer that is a real binding still lands here and can be named.
    for _, entry in ipairs(inventory) do
      if entry.combo ~= RETIRE_KEY and entry.combo ~= SKIP_KEY then
        hl.bind(entry.combo, function() _G.omashift_on_answer(entry.combo) end)
      end
    end
  end)
end

-- Rally stages start on a countdown. Four, not five, because quattro.
local function countdown(n, then_fn)
  if generation ~= _G.omashift_generation then return end
  if n > 0 then
    show { screen = "countdown", n = n, lfg = false, stage = stage_model() }
    hl.timer(function() countdown(n - 1, then_fn) end, { timeout = 1000, type = "oneshot" })
    return
  end
  show { screen = "countdown", n = 0, lfg = true, stage = stage_model() }
  hl.timer(then_fn, { timeout = 700, type = "oneshot" })
end

function _G.omashift_start(opts)
  opts = opts or {}
  -- Per-launch, alongside the co-driver thresholds. Read before anything can
  -- arm a watch, so a stage never runs under the previous launch's value.
  idle_release_ms = tonumber(opts.idle_release_ms) or IDLE_RELEASE_DEFAULT_MS
  -- The launcher sends the mode's NAME and nothing else; core owns the numbers.
  -- An explicit --hint-mods/--hint-full still wins over the preset, keeping the
  -- documented precedence: flags > config > preset > defaults.
  local mode = core.difficulty(opts.difficulty)
  -- Your ghost, rebuilt each launch from unassisted play only. Read here rather
  -- than at load for the same reason as the history: the engine outlives a stage.
  -- ONE parse of the history, here, where a few milliseconds are invisible
  -- because the player is reading the ready screen. Everything the completion
  -- path needs comes out of it, so that path never touches the file again.
  local history = read_history()
  prior_facts = core.history_facts(history, { combos = core.live_combos(inventory) })
  local ghost = prior_facts.ghost

  -- ACTIONS YOU HAVE GIVEN UP ON, dropped before a course ever sees them. A
  -- trainer that keeps asking a question you have twice said you cannot answer
  -- is not training anything, and on a keyboard missing a key that is a loop
  -- with no end: skip it today, it is back tomorrow.
  --
  -- Before the course filter rather than after, so a course whose entire
  -- contents are retired reports itself empty and refuses to start, instead of
  -- starting and then having nothing to ask.
  local live = core.without_retired(inventory, history)
  local pool = live
  if opts.course and opts.course ~= "" then
    -- Read at arm time, not at load: Blind Spots must see the record the stage
    -- before it wrote, and the engine stays loaded across stages.
    pool = core.filter_course(live, opts.course, history)
    -- A dynamic course with nothing in it must NOT fall through to the full
    -- bank. The player asked for their weak spots; silently serving the whole
    -- inventory instead is the worst possible answer. Say so, and stay out of
    -- game mode -- their keybindings are still live at this point.
    -- A COURSE WITH NOTHING IN IT REFUSES, WHATEVER KIND IT IS.
    --
    -- Only the dynamic one used to. A curated course that matched nothing fell
    -- through to the whole bank, which is the worst available answer: the
    -- player asked for Apps and silently got all 199 bindings at random, a set
    -- the design's own notes call unwinnable by construction for a new player.
    --
    -- It cannot happen on the keymap these courses were written against, which
    -- is exactly why it is worth refusing rather than trusting. Courses match on
    -- binding DESCRIPTIONS, so anyone who has renamed theirs, trimmed them, or
    -- is not on Omarchy at all can land here, and this game has run on one
    -- machine.
    local spec = core.COURSES[opts.course]
    if #pool == 0 then
      show { screen = "empty_course", course = opts.course,
             label = spec and spec.label or opts.course,
             dynamic = (spec and spec.dynamic) == true,
             scene = scene_for(opts.course) }
      return
    end
  end
  -- Anki's queue order: overdue reviews first, then never-seen (Blind Spots),
  -- then filler. Oversample so the shuffle still has something to work with.
  local length = opts.length or 10
  pool = core.select_due(pool, schedule, today, math.max(length * 3, length))
  stage = core.new_stage(pool, {
    length = length,
    seed = opts.seed or (last_timestamp % 100000) + 1,
    course = opts.course,
    difficulty = opts.difficulty,
    tier_scale = mode.tier_scale,
    ghost = ghost,
    codriver_mods_ms = opts.codriver_mods_ms or mode.hint_mods,
    codriver_full_ms = opts.codriver_full_ms or mode.hint_full,
  })
  -- Enter game mode ONLY now. Everything above is preparation; the player's
  -- keybindings stay live until this line.
  hl.dispatch(hl.dsp.submap(SUBMAP))
  countdown(4, advance)
end

-- Called by the display before the player is ready, so the start screen can be
-- shown without suppressing anything.
-- `mods_ms` may be empty: the co-driver timing usually comes from the difficulty
-- preset, which lives in core. The display cannot resolve that, because it is a
-- shell script and the presets are deliberately Lua-only, so it hands over what the
-- player explicitly asked for, if anything, and the engine fills in the rest.
-- Passing a bash-side default here is what made the start screen advertise 2s
-- while the medium preset was actually 4s.
function _G.omashift_preview(notes, mods_ms, course, difficulty)
  local ms = tonumber(mods_ms)
  if not ms or ms <= 0 then ms = core.difficulty(difficulty).hint_mods end
  local secs = math.floor(ms / 1000)
  show {
    screen = "ready",
    course = (course ~= "" and course) or nil,
    difficulty = (difficulty ~= "" and difficulty) or core.DEFAULT_DIFFICULTY,
    notes = tonumber(notes),
    codriver_s = secs,
    -- In the model rather than baked into the formatter. It is still a hardcoded
    -- chord, but it is hardcoded in ONE place that knows what launched the game,
    -- instead of inside a renderer that cannot possibly know.
    launch_key = LAUNCH_KEY,
    -- The menu wears the course it is about to run, so choosing one shows you
    -- what you are choosing.
    scene = scene_for((course ~= "" and course) or nil),
  }
end

-- This one had no `publish` at all: it rendered text and nothing else, which
-- made it the single easiest screen in the merge to drop on the floor.
-- The first frame anyone sees. It used to carry no backdrop, so the game
-- opened on the drawn sky and then cut to a photograph the moment a course was
-- armed: a sunrise flashing up on the way in to a game about winding roads.
show { screen = "loaded", bindings = #inventory, scene = scene_for(nil) }

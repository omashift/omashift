-- Tests for lib/engine.lua, driven offline against a fake Hyprland.
-- Run directly:  lua test/test-engine.lua
--
-- Read hl-stub.lua first for why this is possible at all, and for the line
-- between what this covers and what only ./test/smoke can.
--
-- The assertions here are aimed squarely at the failure shapes this project has
-- actually suffered, all four of which survived a fully green suite and were
-- found by playing:
--
--   1. a function called but never defined (persist, show_telemetry)
--   2. configuration silently dropped before it reached its consumer
--   3. a completed stage leaving the player stranded in the submap
--   4. the text screen and the structured screen drifting apart
--
-- Every one of those is now a test failure instead of a bad evening.

package.path = (arg[0]:match("(.*/)") or "./") .. "../lib/?.lua;" .. package.path
local H = dofile((arg[0]:match("(.*/)") or "./") .. "hl-stub.lua")

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

local function contains(label, needle, haystack)
  if type(haystack) == "string" and haystack:find(needle, 1, true) then ok(label)
  else fail(label, "contains " .. needle, haystack) end
end

local function absent(label, needle, haystack)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then ok(label)
  else fail(label, "does not contain " .. needle, haystack) end
end

local ENGINE = (arg[0]:match("(.*/)") or "./") .. "../lib/engine.lua"

-- Load a fresh engine into a fresh sandbox. Returns the stub handle and the box.
-- `prepare` runs after the sandbox exists and BEFORE the engine loads, which is
-- the only window for anything the engine reads at load time. Custom courses
-- are read in a do-block at the top of engine.lua, so a file written after boot
-- is a file the engine has already decided not to see.
--
-- It replaces an `env` parameter that was declared and never used.
local function boot(name, prepare)
  local box = H.sandbox(name)
  if prepare then prepare(box) end
  local hl = H.install()
  hl.reset_globals()
  local restore = H.with_env({
    OMASHIFT_BASE       = box.root,
    OMASHIFT_STATE      = box.state,
    OMASHIFT_STATE_JSON = box.json,
    XDG_STATE_HOME      = box.root .. "/state",
    XDG_CONFIG_HOME     = box.root .. "/config",
  })
  local loaded, err = pcall(dofile, ENGINE)
  restore()
  return hl, box, loaded, err
end

-- Idle release is a safety net for a human who walked away. Under a virtual
-- clock it is just a timer racing the script, so every driven stage pushes it
-- out of reach rather than fighting it.
local FAR = 60 * 60 * 1000

local function start(hl, box, opts)
  opts = opts or {}
  opts.idle_release_ms = opts.idle_release_ms or FAR
  opts.length = opts.length or 3
  opts.seed = opts.seed or 42
  local restore = H.with_env({
    OMASHIFT_BASE       = box.root,
    OMASHIFT_STATE      = box.state,
    OMASHIFT_STATE_JSON = box.json,
    XDG_STATE_HOME      = box.root .. "/state",
    XDG_CONFIG_HOME     = box.root .. "/config",
  })
  _G.omashift_start(opts)
  restore()
end

local INVENTORY = dofile((arg[0]:match("(.*/)") or "./") .. "fixtures/inventory.lua")

local function combo_for(description)
  for _, e in ipairs(INVENTORY) do
    if e.description == description then return e.combo end
  end
end

-- Deliver a key event, which is what makes the engine re-read held modifiers.
-- The handler defers by one loop turn because Hyprland updates its pressed-key
-- set after the event fires, so the advance has to outlast that.
local function keystroke(hl)
  _G.omashift_on_key(1, hl.now(), 1)
  hl.advance(50)
end

local function current_prompt(box)
  return box:model():match('"prompt":%s*{.-"description":"([^"]*)"')
end

-- Play a stage to completion, answering every prompt correctly.
-- Returns the descriptions in the order they were asked.
local function play(hl, box, opts)
  start(hl, box, opts)
  hl.advance(6000)                       -- countdown, four notes plus the LFG beat
  local asked = {}
  for _ = 1, 40 do
    local desc = current_prompt(box)
    if not desc then break end
    asked[#asked + 1] = desc
    _G.omashift_on_answer(combo_for(desc))
    hl.advance(1500)
  end
  return asked
end

print("engine (offline, stubbed compositor):")

-- --- it loads at all --------------------------------------------------------
-- The cheapest and most valuable assertion in the file. Three of this project's
-- four silent breakages would have failed right here.
do
  local hl, box, loaded, err = boot("load")
  truthy("engine.lua loads under plain lua", loaded)
  if not loaded then print("       " .. tostring(err)) end
  eq("it defines exactly one submap", 1, #hl.submaps)
  eq("the submap is named omashift", "omashift", hl.submaps[1])
  truthy("it fills the submap with bindings", #hl.binds > 150)
  truthy("omashift_start is defined", type(_G.omashift_start) == "function")
  truthy("omashift_on_answer is defined", type(_G.omashift_on_answer) == "function")
  truthy("omashift_on_retire is defined", type(_G.omashift_on_retire) == "function")
  contains("it announces the loaded bank", "bindings in the bank", box:text())
  box:remove()
end

-- --- the panic exit is always bound ----------------------------------------
-- The dead-man's switch. If this ever stops being bound, a crash mid-stage
-- leaves a desktop with no keybindings and no way out.
do
  local hl, box = boot("panic")
  local found = false
  for _, k in ipairs(hl.binds) do
    if k == "SUPER + SHIFT + ESCAPE" then found = true break end
  end
  truthy("the panic exit is bound inside the submap", found)
  box:remove()
end

-- --- a whole stage runs -----------------------------------------------------
do
  local hl, box = boot("stage")
  -- Before the merge this was "none": the load banner rendered text and
  -- published nothing, so the overlay could not see it at all. It has a model now.
  eq("the load banner is a real screen, not just text", "loaded", box:screen())

  start(hl, box, { length = 3 })
  eq("starting shows the countdown", "countdown", box:screen())

  hl.advance(6000)
  eq("the countdown gives way to a prompt", "prompt", box:screen())
  truthy("a prompt has a description", current_prompt(box) ~= nil)

  local asked = {}
  for _ = 1, 10 do
    local desc = current_prompt(box)
    if not desc then break end
    asked[#asked + 1] = desc
    _G.omashift_on_answer(combo_for(desc))
    hl.advance(1500)
  end

  eq("a three-note stage asks three notes", 3, #asked)
  eq("finishing a stage shows the results", "results", box:screen())
  contains("the results screen says the stage is complete", "STAGE COMPLETE", box:text())
  contains("and reports every note correct", "3 / 3", box:text())

  -- REGRESSION: show_telemetry was called but never defined, and the suite was
  -- green. It renders a few seconds after the summary, so it only breaks for
  -- someone who is still looking at the screen.
  hl.advance(5000)
  truthy("the telemetry screen renders after the summary",
         box:text():find("NOTES", 1, true) ~= nil)
  box:remove()
end

-- --- REGRESSION: a second start while a stage is live must be ignored -------
-- ENTER held down, or pressed again because the countdown had not appeared on
-- screen yet, is a second independent process reaching `_G.omashift_start`
-- while the first stage's countdown is still ticking. Found by playing on one
-- machine's launch.log: three afternoon bursts of a dozen-odd "started" lines
-- within a couple of seconds of each other, each one an overlapping
-- `countdown()` chain racing another over the single shared `stage`, which is
-- what a countdown speeding through and a whole set of pace notes blazing past
-- with no pause for an answer turned out to be.
do
  local hl, box = boot("restart-guard")
  start(hl, box, { length = 3 })
  contains("starting shows the first tick of the countdown", '"n":4', box:model())

  hl.advance(1000)
  contains("the countdown has ticked down once, on its own", '"n":3', box:model())

  -- A second start, as if a second press had landed on top of the first.
  start(hl, box, { length = 5 })
  contains("the second start is ignored: no fresh countdown, no new note count",
           '"n":3', box:model())

  hl.advance(6000)
  local asked = {}
  for _ = 1, 10 do
    local desc = current_prompt(box)
    if not desc then break end
    asked[#asked + 1] = desc
    _G.omashift_on_answer(combo_for(desc))
    hl.advance(1500)
  end
  eq("the original three-note stage still asks exactly three, never five",
     3, #asked)
  eq("and it still reaches the results screen, not a stomped one", "results", box:screen())
  box:remove()
end

-- --- REGRESSION: a completed stage must hand the keys back ------------------
-- Found by playing, not by the suite. The summary rendered while every
-- keybinding stayed dead and there was nothing left to answer.
do
  local hl, box = boot("handback")
  play(hl, box, { length = 3 })

  -- Assert the RESET specifically. "dispatches > 0" was the first version of
  -- this and fault injection proved it worthless: the engine dispatches
  -- submap(omashift) to enter game mode, so the count is already non-zero before
  -- the stage ends, and commenting out hand_back() left the suite green.
  truthy("the engine entered game mode", hl.dispatched_submap("omashift"))
  truthy("completing a stage resets the submap", hl.dispatched_submap("reset"))
  eq("and the reset is the LAST thing it dispatches", "reset",
     hl.submap_dispatches()[#hl.submap_dispatches()])

  -- hand_back has a second half. Restoring the hint overlay is part of giving
  -- the desktop back, and it went missing once already.
  local restored = false
  for _, c in ipairs(hl.exec) do
    if c:find("omashift-guide-restore", 1, true) then restored = true end
  end
  truthy("and the hint overlay is restored on the way out", restored)
  box:remove()
end

-- --- REGRESSION: configuration must survive the trip ------------------------
-- The co-driver was once called without its config, and omashift_start dropped
-- that config before it reached new_stage. Both survived a green suite.
do
  local hl, box = boot("config")
  start(hl, box, { length = 3, difficulty = "hard", course = "daily-driver" })
  hl.advance(6000)
  local model = box:model()
  contains("the published model names the course", '"course":"daily-driver"', model)
  contains("the published model names the difficulty", '"difficulty":"hard"', model)
  box:remove()
end

-- --- the co-driver speaks when you wait, and not before ---------------------
do
  local hl, box = boot("codriver")
  start(hl, box, { length = 3, difficulty = "easy" })
  hl.advance(6000)
  absent("no hint before the co-driver's threshold", '"hint"', box:model())
  hl.advance(10000)
  contains("waiting long enough calls the note", '"hint"', box:model())

  -- The stage is not marked assisted until the called note is ANSWERED. The
  -- flag describes what the stage has recorded, not what is on screen.
  _G.omashift_on_answer(combo_for(current_prompt(box)))
  hl.advance(1500)
  contains("answering a called note marks the stage assisted", '"assisted":true', box:model())
  box:remove()
end

-- --- the retire path -------------------------------------------------------
do
  local hl, box = boot("retire")
  start(hl, box, { length = 5 })
  hl.advance(6000)
  eq("a stage is running", "prompt", box:screen())
  _G.omashift_on_retire()
  eq("retiring releases the player", "released", box:screen())
  contains("and says why", '"reason":"retired"', box:model())
  truthy("retiring resets the submap too", hl.dispatched_submap("reset"))
  box:remove()
end

-- --- skipping one note, rather than the whole stage -------------------------
--
-- The gap this closes, from a real session: a keymap can contain a binding this
-- keyboard cannot produce, and a laptop with no PrintScreen key had three. The
-- note could not be answered, missing it requeued it, and the only ways out
-- were retiring the stage or sitting through the idle release. A ten note stage
-- delivered twenty-three prompts and never ended.
do
  local hl, box = boot("skip")
  start(hl, box, { length = 4 })
  hl.advance(6000)
  eq("a stage is running", "prompt", box:screen())

  truthy("omashift_on_skip is defined", type(_G.omashift_on_skip) == "function")
  contains("and the prompt says how to skip", '"skip_key"', box:model())

  local stuck = current_prompt(box)
  _G.omashift_on_skip()
  eq("skipping shows a result", "result", box:screen())
  contains("marked as skipped, not as an off", '"outcome":"skipped"', box:model())
  -- It must not read as a crash. An off costs a gear and feeds Blind Spots; a
  -- chord nobody can press deserves neither.
  absent("and it is not scored", '"points":%d%d', box:model())

  hl.advance(1500)
  eq("and the stage moves on", "prompt", box:screen())
  truthy("to a different note", current_prompt(box) ~= stuck)

  -- THE LOOP. A skipped note is never requeued, so it cannot come back and be
  -- skipped again for the rest of the stage.
  local seen = {}
  for _ = 1, 40 do
    local desc = current_prompt(box)
    if not desc then break end
    seen[desc] = (seen[desc] or 0) + 1
    _G.omashift_on_answer(combo_for(desc))
    hl.advance(1500)
  end
  eq("the skipped note never comes back", nil, seen[stuck])
  box:remove()
end

-- --- handing back stops everything that can still draw ---------------------
--
-- `repaint` was cleared when an answer landed and nowhere else. After an idle
-- release the key listener still held a closure over the last pace note, so the
-- next modifier press redrew it with no stage behind it: a prompt screen
-- reading "0 / 0", showing the note the player had just escaped, offering a
-- retire chord that no longer did anything. It looked like a loop.
do
  local hl, box = boot("stale-repaint")
  start(hl, box, { length = 4 })
  hl.advance(6000)
  eq("a stage is running", "prompt", box:screen())

  _G.omashift_on_retire()
  eq("retiring releases the player", "released", box:screen())

  -- The exact thing that used to resurrect the prompt.
  keystroke(hl)
  hl.advance(200)
  eq("a keypress afterwards does not redraw the prompt", "released", box:screen())
  box:remove()
end

-- --- a key bound to nothing ------------------------------------------------
--
-- From the same session: the player pressed PrintScreen on its own and got
-- nothing at all back. While a stage runs the submap has replaced every
-- binding, so a key that is not in the question bank is not wrong, it is
-- swallowed. Silence is indistinguishable from a hung game, which is a strange
-- thing for a game about pressing keys to do.
do
  local hl, box = boot("unbound")
  start(hl, box, { length = 4 })
  hl.advance(6000)
  absent("nothing to say before anything is pressed", '"unbound"', box:model())

  -- A key nothing is bound to: the press arrives, no answer follows.
  _G.omashift_on_key(99, hl.now(), 1)
  hl.advance(400)
  contains("an unbound key says so", '"unbound":true', box:model())
  -- And it is NOT an off. Naming no action is not the same as naming the wrong
  -- one, and scoring it would teach nothing.
  eq("without scoring it", "prompt", box:screen())

  hl.advance(2000)
  absent("and the notice clears itself", '"unbound"', box:model())
  box:remove()
end

do
  local hl, box = boot("unbound-answered")
  start(hl, box, { length = 4 })
  hl.advance(6000)
  -- A key that IS bound: the press arrives and so does the answer, so the
  -- notice must never appear. Its whole claim is that nothing happened.
  _G.omashift_on_key(30, hl.now(), 1)
  _G.omashift_on_answer(combo_for(current_prompt(box)))
  hl.advance(400)
  absent("a key that answers never reads as unbound", '"unbound"', box:model())
  box:remove()
end

do
  local hl, box = boot("unbound-repeat")
  start(hl, box, { length = 4 })
  hl.advance(6000)
  -- AUTO-REPEAT IS NOT A NEW PRESS. Holding a modifier repeats its keycode, and
  -- the modifier set does not change because it was already held. Without the
  -- keys-down bookkeeping the game would announce "not bound to anything" in
  -- the middle of a chord being typed, which is the worst possible moment.
  _G.omashift_on_key(64, hl.now(), 1)
  hl.advance(400)
  contains("the first press is heard", '"unbound":true', box:model())
  hl.advance(2000)
  absent("and clears", '"unbound"', box:model())

  -- THE REPEAT. Same keycode, never released. This is what a held key sends,
  -- and it must not read as a new press.
  _G.omashift_on_key(64, hl.now(), 1)
  hl.advance(400)
  absent("a key still held is not pressed again", '"unbound"', box:model())

  -- Released and pressed properly, it is heard again.
  _G.omashift_on_key(64, hl.now(), 0)
  _G.omashift_on_key(64, hl.now(), 1)
  hl.advance(400)
  contains("but a real second press is", '"unbound":true', box:model())
  _G.omashift_on_key(64, hl.now(), 0)
  box:remove()
end

-- --- the keymap comes back a beat after the results page --------------------
--
-- The results page holds exclusive keyboard focus, which swallows Hyprland's
-- own shortcuts, but the compositor grants that focus asynchronously after the
-- surface maps. Handing the keymap back at the same instant leaves a frame or
-- two where the real bindings are live and nothing is catching them.
--
-- A player finishing a Track Day stage had pressed SUPER + SHIFT + 3 three
-- times trying to answer a note. All three were caught and scored. The stage
-- ended on the third, and the same reflex a moment later moved a window to
-- workspace 3 for real.
do
  local hl, box = boot("handback-grace")
  start(hl, box, { length = 2 })
  hl.advance(6000)
  -- Answer every note but stop short of the grace window on the last one: the
  -- result pause is 900ms and the grace is 400 after it, so a 1500ms step would
  -- sail past the thing being measured. The first version of this test did.
  for _ = 1, 8 do
    local desc = current_prompt(box)
    if not desc then break end
    _G.omashift_on_answer(combo_for(desc))
    -- 950: past the 900ms result pause, so the stage advances, and only 50ms
    -- into the 400ms grace, so the hand back has not happened yet.
    hl.advance(950)
    if box:screen() == "results" then break end
  end
  eq("the stage finished", "results", box:screen())
  eq("and the keyboard is still held", "omashift", hl.submap())

  hl.advance(500)
  eq("it comes back a beat later", "", hl.submap())
  box:remove()
end

do
  local hl, box = boot("handback-again")
  start(hl, box, { length = 2 })
  hl.advance(6000)
  for _ = 1, 4 do
    local desc = current_prompt(box)
    if not desc then break end
    _G.omashift_on_answer(combo_for(desc))
    hl.advance(1500)
  end
  eq("the stage finished", "results", box:screen())

  -- ENTER on the results goes straight again, which can start a stage inside
  -- the grace window. That stage owns the submap now, and the deferred hand
  -- back must not reset it out from under a countdown.
  start(hl, box, { length = 2 })
  hl.advance(500)
  eq("a stage started in the grace window keeps the keyboard", "omashift", hl.submap())
  box:remove()
end

-- --- fast hands ------------------------------------------------------------
--
-- The unbound notice is decided by a RACE: the raw key event and the submap's
-- bind are two separate deliveries, and nothing guarantees their order or their
-- spacing. Everything below is a way that race could be lost in a direction
-- that lies to the player, and none of them may.
do
  local hl, box = boot("race-chord")
  start(hl, box, { length = 4 })
  hl.advance(6000)

  -- A CHORD TYPED FAST ENOUGH THAT BOTH KEYS ARRIVE TOGETHER. The modifier and
  -- the letter land before the deferred check runs, so the check sees a changed
  -- modifier set and must not treat the letter as a bare unbound key.
  _G.omashift_on_key(125, hl.now(), 1)      -- the modifier
  _G.omashift_on_key(17, hl.now(), 1)       -- the letter, same instant
  _G.omashift_on_answer(combo_for(current_prompt(box)))
  hl.advance(500)
  absent("a fast chord is not read as an unbound key", '"unbound"', box:model())
  box:remove()
end

do
  local hl, box = boot("race-late")
  start(hl, box, { length = 4 })
  hl.advance(6000)
  local desc = current_prompt(box)

  -- THE BIND ARRIVES LATE, but still inside the window. This is the shape of a
  -- loaded machine: the key event is delivered, the dispatch is delayed, and
  -- the answer lands afterwards.
  _G.omashift_on_key(17, hl.now(), 1)
  hl.advance(300)
  absent("nothing is said while the answer might still be coming", '"unbound"', box:model())
  _G.omashift_on_answer(combo_for(desc))
  hl.advance(100)
  eq("and the answer still lands", "result", box:screen())
  absent("with no notice on it", '"unbound"', box:model())
  box:remove()
end

do
  local hl, box = boot("race-lost")
  start(hl, box, { length = 4 })
  hl.advance(6000)
  local desc = current_prompt(box)

  -- THE RACE LOST OUTRIGHT: the dispatch takes longer than the window, so the
  -- notice appears for a key that was in fact bound. It is wrong, and it is the
  -- reason the window is generous. What must NOT happen is the notice
  -- surviving onto the result: a flash is recoverable, a contradiction is not.
  _G.omashift_on_key(17, hl.now(), 1)
  hl.advance(500)
  contains("a very late answer does flash the notice", '"unbound":true', box:model())
  _G.omashift_on_answer(combo_for(desc))
  hl.advance(100)
  eq("but the answer still lands", "result", box:screen())

  -- THE RISK THAT IS REAL. A result page does not carry the field at all, so
  -- asserting it is absent there proves nothing. What matters is the NEXT pace
  -- note: if the flag survives the answer, the player arrives at a fresh
  -- question already being told their keyboard is broken.
  hl.advance(1200)
  eq("and the stage moves on", "prompt", box:screen())
  absent("with the notice cleared, not carried forward", '"unbound"', box:model())
  box:remove()
end

do
  local hl, box = boot("race-carry")
  start(hl, box, { length = 4 })
  hl.advance(6000)

  -- THE SAME PROPERTY ON THE PATH THAT ONLY ONE THING DEFENDS. An answer clears
  -- the notice itself, so removing the clear in `advance` changes nothing there
  -- and a test built on that path cannot fail. A SKIP does not clear it, so
  -- arriving at the next pace note with a clean screen is `advance` doing its
  -- job and nothing else.
  _G.omashift_on_key(99, hl.now(), 1)
  hl.advance(500)
  contains("the notice is up", '"unbound":true', box:model())

  _G.omashift_on_skip()
  hl.advance(1200)
  eq("after a skip the stage moves on", "prompt", box:screen())
  absent("and the next note is clean", '"unbound"', box:model())
  box:remove()
end

do
  local hl, box = boot("race-settle")
  start(hl, box, { length = 5 })
  hl.advance(6000)
  local first = current_prompt(box)
  _G.omashift_on_answer(combo_for(first))
  eq("an answer shows a result", "result", box:screen())

  -- HAMMERING DURING THE SETTLE. The next pace note is ~900ms away, and a
  -- keypress in that gap used to answer the SAME prompt again, which is how a
  -- six note stage once came back reporting "6 / 7".
  _G.omashift_on_answer(combo_for(first))
  _G.omashift_on_answer(combo_for(first))
  _G.omashift_on_key(17, hl.now(), 1)
  hl.advance(400)
  eq("pressing again during the settle changes nothing", "result", box:screen())
  absent("and says nothing about unbound keys", '"unbound"', box:model())

  hl.advance(1000)
  eq("and the stage moves on exactly once", "prompt", box:screen())
  truthy("to the next note", current_prompt(box) ~= first)
  box:remove()
end

-- --- the release clock ------------------------------------------------------
--
-- A screen that will not move on, on a note that cannot be answered, reads as a
-- hung machine. The clock is what turns waiting from a gamble into a decision.
do
  local hl, box = boot("clock")
  start(hl, box, { length = 4, idle_release_ms = 60000 })
  hl.advance(6000)
  absent("no clock while there is plenty of time", '"release_in_s"', box:model())

  hl.advance(35000)
  contains("it appears as the release gets close", '"release_in_s"', box:model())

  local first = tonumber(box:model():match('"release_in_s":(%d+)'))
  hl.advance(5000)
  local later = tonumber(box:model():match('"release_in_s":(%d+)'))
  truthy("and it counts down", first and later and later < first)

  hl.advance(30000)
  eq("and then the keyboard really does come back", "released", box:screen())
  contains("saying why", '"reason":"idle"', box:model())
  box:remove()
end

-- --- an empty course is refused, not played -------------------------------
do
  local hl, box = boot("empty")
  start(hl, box, { length = 3, course = "blind-spots" })
  eq("a course with nothing due does not start a stage", "empty_course", box:screen())
  contains("and says it is the kind that fills in", '"dynamic":true', box:model())
  box:remove()
end

-- A CURATED COURSE THAT MATCHES NOTHING REFUSES TOO, which it did not until
-- now: it fell through to the whole bank, so a player who asked for Apps got
-- all 199 bindings at random, a set this design's own notes call unwinnable by
-- construction for a new player.
--
-- It cannot happen on the keymap these courses were written against, which is
-- exactly why it is worth refusing rather than trusting. Courses match on
-- binding DESCRIPTIONS, so a renamed or trimmed keymap empties one out, and
-- this game has run on one machine.
do
  -- Written into the box's own config rather than poked into core.COURSES: the
  -- engine loads its own copy of core.lua, so mutating the suite's copy changes
  -- nothing the engine can see. It also makes this the realistic case, which is
  -- somebody's own course in their own courses.lua.
  local hl, box = boot("empty-curated", function(b)
    os.execute(("mkdir -p %q"):format(b.root .. "/config/omashift"))
    local cf = assert(io.open(b.root .. "/config/omashift/courses.lua", "w"))
    cf:write('return { ["matches-nothing"] = { label = "Matches Nothing", ',
             'patterns = { "^ThisDescriptionExistsNowhere$" } } }\n')
    cf:close()
  end)

  start(hl, box, { length = 3, course = "matches-nothing" })

  eq("a curated course with no matches refuses", "empty_course", box:screen())
  absent("and does not serve the whole bank", '"screen":"countdown"', box:model())
  -- The advice has to differ: playing more will not populate a course that
  -- matches nothing in your keymap.
  absent("and does not claim it will fill in", '"dynamic":true', box:model())
  box:remove()
end

-- --- the modifier wheels track what is held --------------------------------
do
  local hl, box = boot("wheels")
  start(hl, box, { length = 3 })
  hl.advance(6000)
  absent("nothing is held to begin with", '"SUPER":true', box:model())

  -- Holding a key is not enough on its own. The wheels repaint from the key
  -- EVENT handler, and only when the held-modifier signature actually changes,
  -- which is the comparison that made the old (keycode, timestamp) dedupe
  -- redundant. Simulating the hold without the event tests nothing.
  hl.hold("Super_L")
  keystroke(hl)
  contains("holding SUPER lights its wheel", '"SUPER":true', box:model())

  hl.hold("Control_L", "Alt_L", "Shift_L")
  keystroke(hl)
  contains("holding all four is full quattro", '"quattro":true', box:model())

  hl.release_all()
  keystroke(hl)
  absent("letting go puts the wheels out", '"SUPER":true', box:model())
  box:remove()
end

-- --- REGRESSION: text and model must describe the same screen ---------------
-- This is the duplication the render/publish merge exists to remove. Until it
-- is merged, the two are hand-kept in sync, so pin them together.
do
  local hl, box = boot("agreement")
  play(hl, box, { length = 3 })
  eq("both halves agree the stage finished", "results", box:screen())
  contains("the text half says so too", "STAGE COMPLETE", box:text())

  local text_correct = box:text():match("correct%s+(%d+)%s*/%s*(%d+)")
  -- Anchored to the summary on purpose: `splits` sorts before `summary` in the
  -- serialized model and every split carries its own `correct`, so a bare
  -- '"correct":(%d+)' reads a per-category count and quietly compares the wrong
  -- two numbers.
  local model_correct = box:model():match('"summary":%s*{.-"correct":(%d+)')
  eq("both halves report the same correct count", text_correct, model_correct)
  box:remove()
end

-- --- determinism ------------------------------------------------------------
-- A seeded stage in a clean sandbox must ask the same notes every time, or none
-- of the golden-file work the render/publish merge depends on is possible.
do
  local first
  local stable = true
  for i = 1, 3 do
    local hl, box = boot("determinism" .. i)
    local asked = table.concat(play(hl, box, { length = 3, seed = 7 }), "|")
    if not first then first = asked elseif asked ~= first then stable = false end
    box:remove()
  end
  truthy("the same seed asks the same notes across runs", stable)
  truthy("and it actually asked something", first and #first > 0)
end

-- --- a different seed is a different stage ---------------------------------
-- Negative control. Without it, a harness that always returned the same three
-- notes for any input would pass the determinism check above.
do
  local hl1, box1 = boot("seedA")
  local a = table.concat(play(hl1, box1, { length = 5, seed = 1 }), "|")
  box1:remove()
  local hl2, box2 = boot("seedB")
  local b = table.concat(play(hl2, box2, { length = 5, seed = 999 }), "|")
  box2:remove()
  truthy("a different seed asks different notes", a ~= b)
end

-- --- THE WATCHDOG ----------------------------------------------------------
-- Taking the keyboard is never allowed to be permanent. A submap left engaged
-- captures every key, and the launch chord is itself in the question bank, so a
-- stuck submap answers the player's attempt to relaunch as a pace note. There is
-- no route to a terminal either. This happened to a real player.
do
  local hl, box = boot("watchdog")
  -- The state that strands someone: submap engaged, no stage, nothing drawing.
  hl.strand("omashift")
  eq("the keyboard starts captured", "omashift", hl.submap())

  hl.advance(60000)
  eq("it does not fire early", "omashift", hl.submap())

  hl.advance(40000)
  eq("but it does give the keyboard back", "", hl.submap())
  eq("and says the game stopped responding", "released", box:screen())
  contains("naming the watchdog as the reason", '"reason":"watchdog"', box:model())
  contains("in words a player can act on", "stopped responding", box:text())
  box:remove()
end

-- It must survive an engine reload, or it dies with the stage that armed it.
-- That is the whole difference between this and the per-prompt idle release.
do
  local hl, box = boot("watchdog-reload")
  hl.strand("omashift")
  -- A reload replaces the engine but must NOT re-register the timer chain, and
  -- must not leave the old one pointing at a dead engine either.
  local restore = H.with_env({
    OMASHIFT_BASE = box.root, OMASHIFT_STATE = box.state,
    OMASHIFT_STATE_JSON = box.json, XDG_STATE_HOME = box.root .. "/state",
    XDG_CONFIG_HOME = box.root .. "/config",
  })
  dofile((arg[0]:match("(.*/)") or "./") .. "../lib/engine.lua")
  restore()
  hl.advance(100000)
  eq("a reloaded engine is still watched", "", hl.submap())
  box:remove()
end

-- The watchdog re-arms itself forever, so its registration guard is load-bearing
-- in the same way the key listener's is. This project has been bitten twice by
-- unbounded compositor-side growth: a key listener re-subscribed on every reload,
-- and a submap binding leak that reached 5,687 entries. A timer chain that
-- re-registers on every reload is the same shape.
do
  local hl, box = boot("watchdog-leak")
  hl.advance(6000)
  local baseline = hl.pending()
  for _ = 1, 5 do
    local restore = H.with_env({
      OMASHIFT_BASE = box.root, OMASHIFT_STATE = box.state,
      OMASHIFT_STATE_JSON = box.json, XDG_STATE_HOME = box.root .. "/state",
      XDG_CONFIG_HOME = box.root .. "/config",
    })
    dofile(ENGINE)
    restore()
    hl.advance(6000)
  end
  -- Five reloads must not leave five watchdogs ticking. Allowing a little slack
  -- for whatever else is legitimately scheduled, but not five chains' worth.
  truthy(("five reloads do not multiply the watchdog (pending %d -> %d)")
           :format(baseline, hl.pending()),
         hl.pending() <= baseline + 1)
  box:remove()
end

-- A live stage draws constantly, so the watch must never interrupt real play.
do
  local hl, box = boot("watchdog-quiet")
  start(hl, box, { length = 10 })
  hl.advance(6000)
  eq("a stage is running", "prompt", box:screen())
  -- Deliberately longer than the watchdog window. Eight answers at ten seconds
  -- came to eighty, which is UNDER ninety, so a watchdog that had stopped being
  -- reset by a screen write would still not have fired and the test would have
  -- passed while the reset was broken. Play has to outlast the watch to prove
  -- the watch is being fed.
  for _ = 1, 14 do
    local d = current_prompt(box)
    if not d then break end
    _G.omashift_on_answer(combo_for(d))
    hl.advance(10000)              -- slow play, but play
  end
  truthy("steady play is never interrupted by the watchdog",
         box:model():find('"reason":"watchdog"', 1, true) == nil)
  box:remove()
end

-- The one exemption is narrow ON PURPOSE: a LIVE stage whose player turned the
-- idle release off has chosen to hold the keyboard. No stage is never a choice.
do
  local hl, box = boot("watchdog-optout")
  hl.strand("omashift")
  hl.advance(100000)
  eq("idle_release=0 does not exempt a submap with no stage", "", hl.submap())
  box:remove()
end

-- --- the backdrop is resolved, not guessed ---------------------------------
-- The engine turns a course's theme name into a path that EXISTS, so a theme
-- this machine does not have arrives as nothing and the overlay falls back to
-- the sky it has always drawn. A renderer building the path itself would have
-- no way to know the file is missing, and would show a blank rectangle with
-- nothing anywhere to say why.
do
  local hl, box = boot("scene")
  start(hl, box, { length = 3, course = "daily-driver" })
  hl.advance(6000)
  local model = box:model()
  contains("a stage carries its backdrop", '"scene"', model)
  contains("resolved to a real path", '"image":"/', model)
  contains("with a scrim to read over", '"scrim"', model)

  -- Whatever it published has to be a file that is actually there.
  local path = model:match('"image":"([^"]+)"')
  local f = path and io.open(path, "r")
  truthy("and the file exists", f ~= nil)
  if f then f:close() end
  box:remove()
end

-- --- play is recorded ------------------------------------------------------
-- REGRESSION: persist() was called but never defined. Without history there is
-- no ghost, no Blind Spots and no Cabinet, and nothing else notices.
do
  local hl, box = boot("history")
  play(hl, box, { length = 3 })
  local f = io.open(box.root .. "/history.jsonl", "r")
  truthy("a completed stage is written to history", f ~= nil)
  if f then
    local line = f:read("*l")
    f:close()
    truthy("the history line is a record of the stage", line and line:find('"answers"', 1, true))
  end
  box:remove()
end

print()
if failed == 0 then
  print(("\27[32mengine: %d passed\27[0m"):format(run))
  os.exit(0)
end
print(("\27[31mengine: %d of %d FAILED\27[0m"):format(failed, run))
os.exit(1)

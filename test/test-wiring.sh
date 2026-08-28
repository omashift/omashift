#!/bin/bash
# Wiring checks for lib/engine.lua.
#
# NOTE: these grep assertions predate test-engine.lua, which now drives the
# engine for real against a stubbed compositor. They are kept because they are
# cheap and they pin call SHAPES rather than behavior, but behavioral coverage
# belongs in test-engine.lua now. Prefer adding there.
#
# The original rationale, left for context: the engine was believed to require a
# live Hyprland, so its logic
# lives in core.lua and this file guards the SEAM between them. That seam has
# now silently broken three times: persist() was called but never defined, the
# co-driver was called without its config, and omashift_start dropped that
# config before it reached new_stage. Each survived a passing suite and was
# only found by playing.
#
# These are grep assertions, not behavior tests. They are deliberately crude:
# their only job is to fail loudly when a required call shape disappears.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
source ./helpers.sh

# AN ASSERTION THAT DOES NOT EXIST YET IS NOT A FAILING ASSERTION, IT IS NO
# ASSERTION AT ALL.
#
# This file is long, its helpers used to be defined next to the section that
# first needed them, and `set -e` is deliberately off so that one failed check
# does not hide the rest. The three together are silent: an assertion written
# above its own helper prints "command not found" to stderr, runs nothing, and
# the suite still reports every remaining check as passed. Eight of them were
# doing exactly that, added above `has_in`, for as long as it took to notice the
# stderr noise.
#
# Now it is fatal and it says which name and where. The helpers themselves have
# all moved to the top, which is the actual fix; this is what stops the same
# mistake being invisible next time.
# A MARKER FILE, not a variable and not an exit. Bash runs this hook in a
# subshell: `exit` inside it ends the hook and the script carries straight on,
# and a variable set here never reaches the parent. A file is the only signal
# that survives, and it is checked at the very end so a real failure list is
# never buried by it.
MISSING_HELPER=$(mktemp -u)
command_not_found_handle() {
  printf '\033[31mFATAL\033[0m %s is not defined at this point in the file.\n' "$1" >&2
  printf '       An assertion above its own helper runs nothing and reports nothing.\n' >&2
  printf '       Move the helper up, or the assertion down.\n' >&2
  echo "$1" >> "$MISSING_HELPER"
}

# Every file under test, in ONE place.
#
# These used to be declared next to the section that first needed them, so an
# assertion added above its own variable aborted the entire suite under `set -u`
# and printed no summary at all -- which reads as the suite vanishing rather than
# failing. Declaring them together costs nothing and removes the ordering trap.
E=../lib/engine.lua        # the engine
S=../lib/screens.lua       # the text screens
Q=../qml/Surface.qml       # the overlay surface
SH=../qml/shell.qml        # the overlay root
CB=../bin/omashift-cabinet # the trophy case
ST=../bin/omashift-stats   # the logbook
L=../bin/omashift          # the launcher
       # the text screens
       # the overlay surface
        # the overlay root
 # the trophy case
# Screen text lives here since the render/publish merge. Assertions about what a
# screen SAYS point at this file; assertions about engine flow still point at $E.

echo "engine wiring:"

has() { grep -qF -- "$2" "$E" && _pass "$1" || _fail "$1" "engine.lua contains: $2" "absent"; }
says() { grep -qF -- "$2" "$S" && _pass "$1" || _fail "$1" "screens.lua contains: $2" "absent"; }

# Assert a needle appears INSIDE a function body, delimited by the function's
# opening line and the next `end` in column 0. A fixed grep -A/-B window would
# do here, and did, until lines were added above the needle and it silently
# fell outside the window. Scope beats distance.
body() { # <label> <function opening line> <needle>
  awk -v start="$2" -v needle="$3" '
    # Bound the scan at a top-level `end` OR the next top-level definition.
    # `end` alone is not enough: a one-liner like
    #   _G.omashift_on_answer = function(combo) handle(combo) end
    # never matches /^end$/, so the scan ran on into the NEXT function and
    # reported its contents as a match. Caught by a negative control.
    inside && (/^end$/ || /^(local )?function /  || /^_G\.[A-Za-z_]+ = function/) { inside = 0 }
    index($0, start) { inside = 1 }
    inside && index($0, needle) { found = 1 }
    END { exit !found }
  ' "$E" && _pass "$1" || _fail "$1" "$3 inside: $2" "absent"
}

# The gate is the launcher noticing an armed stage. No global binding is added,
# so there is nothing that can strand a keyboard.
# `--` before the pattern on purpose. Without it a needle that begins with a
# dash, like "--visual", is parsed by grep as an option and silently matches
# nothing, so the assertion fails on code that is perfectly correct.
has_in() { grep -qF -- "$3" "$2" && _pass "$1" || _fail "$1" "$3" "absent"; }

# Count matches in CODE, with line comments stripped first.
#
# An assertion about code that greps prose flags its own explanation and fails on
# correct source. This project has now done that four separate times: commit
# 13e025b ("that assertion was flagging its own explanation"), the guard chunk,
# the shared-dismissal id, and the results footer. Four is enough for a helper
# rather than a habit.
#
# Strips `//` and `--` line comments, which covers QML, JavaScript and Lua. Not
# for shell files, where `#` is also a legitimate character.
code_count() { # <file> <fixed-string>
  # Full-line `#` comments go too, for shell files. Only FULL-LINE: `#` is a
  # legitimate character mid-code in shell (${#arr}, $#), so stripping it
  # everywhere would eat real assertions.
  sed -e 's,//.*,,' -e 's,--.*,,' -e '/^[[:space:]]*#/d' "$1" | grep -cF -- "$2"
}


# Reaction timing must use a single monotonic clock. Hyprland's key-event
# timestamps are on a different timebase from /proc/uptime and cannot be mixed;
# doing so produced a 6,667,578 ms average.
has "prompts are timestamped with now_ms()"        "core.next_prompt(stage, now_ms())"
has "answers are timestamped with now_ms()"        "core.answer(stage, combo, now_ms()"

# Configured co-driver timing must reach both the hint and the stage.
has "the co-driver receives its config"            "core.hint_for(prompt, elapsed, stage.codriver)"
has "start forwards the mods threshold"            "codriver_mods_ms = opts.codriver_mods_ms"
has "start forwards the full threshold"            "codriver_full_ms = opts.codriver_full_ms"

# Blind Spots is the one course whose entries come from a FILE rather than a
# pattern list, so the history has to actually reach the filter. Passing only
# (inventory, course) leaves the course empty, and the empty-pool fallback below
# then silently hands the player the whole 195-binding bank instead.
# ONE PARSE, PASSED AROUND. It used to call read_history() twice at arm time,
# once for the ghost and once for the filter, on a file that grows with every
# stage played. The assertion is the property, not the spelling: the history is
# read into a local and that local reaches the filter.
has "the course filter receives history"           "core.filter_course(live, opts.course, history)"
assert_eq "and the history is parsed once at arm time" 1 \
  "$(sed -n '/^function _G.omashift_start/,/^end/p' "$E" | grep -c 'read_history()')"
has "read_history() is defined"                    "local function read_history()"
# Read at arm time, not at load. The engine stays resident across stages, so a
# history slurped at load would be stale by the second stage of a session.
body "history is read inside omashift_start" \
  "function _G.omashift_start(opts)" "read_history()"

# AN EMPTY COURSE MUST NOT FALL THROUGH TO THE FULL BANK, whatever kind it is,
# and must not enter game mode. Both halves matter: the fallthrough is the wrong
# stage, and entering the submap anyway would strand the player with no bindings
# and nothing to answer.
#
# Only the dynamic course used to refuse. A curated one that matched nothing
# served all 199 bindings at random, which the design's own notes call
# unwinnable by construction for a new player. It cannot happen on the keymap
# these courses were written against, which is exactly why it is worth refusing
# rather than trusting: courses match on binding DESCRIPTIONS, and this game has
# run on one machine.
has "an empty course bails out"                    "if #pool == 0 then"
# `pool = live` appears once, as the INITIAL value for a stage with no course
# selected, which is correct. What must not come back is a second one, assigning
# it after the pool was found empty. (The first version of this counted the
# string and failed on the initialisation, which is not the thing being tested.)
assert_eq "and never falls back to the whole bank" 1 "$(code_count "$E" "pool = live")"
assert_eq "with no fallback after an empty filter" 0 \
  "$(code_count "$E" "if #pool == 0 then pool = live end")"
if grep -A12 'if #pool == 0 then' "$E" | grep -qF 'return'; then
  _pass "the empty-course branch returns before the submap"
else
  _fail "the empty-course branch returns before the submap" "a return inside the branch" "absent"
fi
# The screen has to say WHICH kind of empty: a dynamic course has nothing to say
# yet, a curated one matched nothing and playing more will not change that.
has "the screen knows which kind"                  "dynamic = (spec and spec.dynamic) == true"
has_in "and the text splits on it"                 "$S" "m.dynamic"
has_in "and so does the overlay"                   "$Q" "doc.dynamic"

# A stage that is never persisted leaves no trace for scheduling or Blind Spots.
has "persist() is defined"                         "local function persist()"
has "completion persists"                          "persist()"
# Retiring must persist before discarding: a partial run carries the signal
# spaced repetition and Blind Spots consume.
body "retiring persists a partial run" \
  "_G.omashift_on_retire = function()" "persist()"

# Every exit from game mode must go through hand_back(). The two halves used to
# disagree: retiring reset the submap but left the hint overlay off for good,
# and COMPLETING a stage did neither. The player sat on a summary screen with
# every binding suppressed and nothing left to answer. Observed by playing.
has "hand_back() is defined"                       "local function hand_back()"
has "hand_back resets the submap"                  'hl.dispatch(hl.dsp.submap("reset"))'
has "hand_back restores the hint overlay"          'hl.exec_cmd(BASE .. "/omashift-guide-restore")'
# A6 was too tight once the call moved into a deferred closure. It still has to
# be on this branch, just a beat later.
if grep -A22 'if not prompt then' "$E" | grep -qF 'hand_back()'; then
  _pass "completing a stage hands the desktop back"
else
  _fail "completing a stage hands the desktop back" "hand_back() on the completion branch" "absent"
fi
# A BEAT LATER, not at the same instant as the results page. The overlay takes
# exclusive keyboard focus asynchronously after its surface maps, so handing the
# keymap back immediately leaves a frame or two where the real bindings are live
# and nothing is catching them. A player mashing SUPER + SHIFT + 3 at a note
# they could not answer moved a window to workspace 3 through exactly that gap.
has "the hand back waits for the overlay"          "HANDBACK_GRACE_MS"
# And stands down if a new stage began in the meantime, since ENTER on the
# results page goes straight again and that stage owns the submap now.
has "and stands down if a stage restarted"         "if stage ~= finished then return end"
body "retiring hands the desktop back" \
  "_G.omashift_on_retire = function()" "hand_back()"

# The idle release: the dead-man's switch assumes the player is there to press
# it, and a player who walks away mid-stage is exactly when they are not.
has "an idle release exists"                       "local IDLE_RELEASE_DEFAULT_MS"
has "the idle watch is armed per prompt"           "start_idle_watch()"
# Configurable per launch like the co-driver thresholds. Reading it anywhere but
# omashift_start would leave a stage running under the PREVIOUS launch's value,
# the engine stays resident across stages.
has "the idle threshold is read per launch"        "idle_release_ms = tonumber(opts.idle_release_ms) or IDLE_RELEASE_DEFAULT_MS"
has "zero disables the watch"                      "if idle_release_ms <= 0 then return end"
body "the threshold is set inside omashift_start" \
  "function _G.omashift_start(opts)" "idle_release_ms = tonumber"
body "an idle release persists the partial run" \
  "local function start_idle_watch()" "persist()"

# The end-of-stage screens must NOT advertise the panic key: it is bound inside
# the submap, so once control is handed back it does nothing. The in-play HUD
# keeps it, because during a stage it really is the way out.
assert_eq "only the in-play HUD advertises the panic key" 1 "$(grep -c 'to retire' "$S")"

# ONE string binds the chord and shows it. Two copies is how a hint ends up
# naming a chord nothing is bound to, which traps a player while they read the
# instructions.
assert_eq "the retire chord is defined once" 1 "$(grep -c '^local RETIRE_KEY = ' "$E")"
has "the chord that is bound is the chord that is shown" "hl.bind(RETIRE_KEY,"
has "and the engine publishes it"                        "retire_key = RETIRE_KEY,"
assert_eq "no second copy of the chord in the engine" 1 "$(grep -c 'SUPER + SHIFT + ESCAPE' "$E")"
assert_eq "and none at all in the formatter" 0 "$(grep -c 'SUPER + SHIFT + ESCAPE' "$S")"

# The overlay is the display John actually runs, and it never showed the way out.
# During a stage every keybinding is a game answer, so `omashift --stop` needs a
# terminal the player cannot open: the on-screen hint is the only escape hatch.

# The whole CONDITION, not just the token. Checking for `doc.retire_key` alone
# passed when the visibility was hardcoded to false, which fault injection caught:
# the hint was still in the file and still never on screen. Nothing offline can
# render QML, so a grep is the honest tool here, and it has to grep the part that
# decides whether a player sees anything.
# THREE WAYS OUT, all on the one screen where they work. Checking for the token
# alone passed once when the visibility was hardcoded to false, which fault
# injection caught: the hint was in the file and never on screen. Nothing
# offline can render QML, so a grep is the honest tool, and it has to grep the
# part that decides whether a player sees anything.
assert_ge "the way out is only shown during play" 1 \
  "$(grep -c 'visible: view === "prompt"$' "$Q")"
assert_eq "the retire chord is gated on the model" 1 "$(grep -c 'visible: !!doc.retire_key' "$Q")"
# Skipping ONE note, for a chord this keyboard cannot produce. Without it the
# only exits from an unanswerable note were retiring the whole stage or waiting.
assert_eq "and the skip chord too"           1 "$(grep -c 'visible: !!doc.skip_key' "$Q")"
# A skip must not be dressed as a crash anywhere on the result page: no OFF
# banner, and no speed readout reading zero.
assert_eq "an off banner is only for an off" 1 "$(grep -c 'visible: parent.r.outcome === "off"' "$Q")"
assert_eq "and no speedometer on a skip"     1 \
  "$(grep -c 'visible: parent.r.outcome !== "skipped"' "$Q")"
# The clock. A screen that will not move on reads as a hung machine, so it says
# the keyboard comes back by itself and exactly when.
assert_eq "and the release clock is shown"   1 \
  "$(grep -c 'doc.release_in_s !== undefined' "$Q")"
assert_eq "and takes the chord from the model, not a literal" 0 "$(grep -c 'SUPER + SHIFT + ESCAPE' "$Q")"
assert_eq "the skip chord is not a literal either" 0 "$(grep -c 'SUPER + CTRL + ESCAPE' "$Q")"

# THE SKIP CHORD IS CHOSEN AGAINST THE PLAYER'S OWN KEYMAP. Hardcoding one would
# shadow a real binding on somebody's machine, making that binding untestable in
# a keybinding trainer.
has_in "the skip chord avoids the bank"    "$E" "local function pick_skip_key(bank)"
has_in "and the submap does not double-bind it" "$E" 'entry.combo ~= SKIP_KEY'
has_in "a skip is not scored as a miss"    ../lib/core.lua 'outcome     = "skipped"'
# The loop this whole thing exists to break.
has_in "a note comes back a bounded number of times" ../lib/core.lua "if seen >= M.REQUEUE_LIMIT then return nil end"
# HANDING BACK HAS TO STOP EVERYTHING THAT DRAWS. `repaint` was cleared when an
# answer landed and nowhere else, so after an idle release the key listener
# still held the last pace note and redrew it with no stage behind it: a prompt
# reading 0 / 0, offering a retire chord that no longer worked.
body "handing back silences the repaint" "local function hand_back()" "repaint = nil"
body "and the co-driver with it"         "local function hand_back()" "codriver_generation ="
body "and the release clock"             "local function hand_back()" "idle_remaining_s = nil"

# Difficulty: core owns the numbers, the engine resolves the NAME. If the engine
# stopped consuming the preset, every stage would silently run at medium and the
# mode flag would appear to work while changing nothing.
body "the engine resolves the difficulty preset" \
  "function _G.omashift_start(opts)" "core.difficulty(opts.difficulty)"
has "the tier scale reaches the stage"             "tier_scale = mode.tier_scale"
# An explicit --hint-* must still beat the preset: flags > config > preset.
has "an explicit hint overrides the preset"        "opts.codriver_mods_ms or mode.hint_mods"
has "an explicit full hint overrides the preset"   "opts.codriver_full_ms or mode.hint_full"

# The result line shows the tier, not a blanket CLEAN. The old fallback printed
# CLEAN for the SLOWEST tier. Flattering feedback pointing the wrong way in a
# game about reaction time.
says "the result line shows the real tier"         'r.praise or (r.tier or "ok"):upper()'

# The ghost: built from history at arm time and handed to the stage. Building it
# and forgetting to pass it would leave every delta nil and the feature silently
# absent. The screen would just never mention a ghost.
body "the ghost is built from history" \
  "function _G.omashift_start(opts)" "core.history_facts(history"
# RETIRED ACTIONS ARE DROPPED BEFORE ANY COURSE SEES THEM, so a course whose
# whole contents are retired reports itself empty and refuses to start, rather
# than starting with nothing to ask.
body "actions given up on are dropped first" \
  "function _G.omashift_start(opts)" "core.without_retired(inventory, history)"
has_in "twice is the threshold"        ../lib/core.lua "M.RETIRE_AFTER_SKIPS = 2"
has_in "and it is read from history"   ../lib/core.lua "function M.retired_actions(history_text, opts)"
# Nothing leaves the rotation silently.
has_in "the second skip announces itself" "$E" "result.retired ="
has_in "and the overlay says so"          "$Q" "that is twice, so it leaves the rotation"
has_in "and the text screens too"         "$S" "so it leaves the rotation"

has "the ghost reaches the stage"                  "ghost = ghost,"
says "the result line shows the ghost split"       "if r.ghost_gap_s then"
says "a new best is announced"                     "NEW BEST"

# User courses are loaded by the ENGINE, because that is what has a Lua
# interpreter at play time. A syntax error in a hand-edited config file must
# cost the player their custom courses and nothing else, so every step is
# wrapped -- an unguarded dofile here takes the whole game down.
has "user courses are loaded"                      'require("courses-file").merge(core, COURSES_FILE)'
has "the courses file is read from XDG config"     'COURSES_FILE = CONFIG_DIR .. "/omashift/courses.lua"'
# ONE LOADER, THREE CALLERS. The engine, `--courses` and `--cycle-course` each
# need the merged list, and for three days only two of them did it -- so a course
# the engine could play was a course the menu could not reach. The pcall that
# used to be asserted here lives in courses-file.lua now.
has_in "loading a bad courses file cannot throw"   ../lib/courses-file.lua "pcall(dofile, path)"
has_in "a missing file is not an error"            ../lib/courses-file.lua "if not f then return 0, {} end"
# FOUR CALLERS NOW, and the fourth was found in a screenshot. The Logbook names
# courses, and its Lua state had never opened courses.lua either, so
# core.course_label fell back to the raw key: every shipped course read
# "Daily Driver" and the one the player actually plays read "cockpit", in the
# by-course table and in "your last stage". It reached the shot that carries the
# announcement. The rule is the one already stated above: a state that SHOWS a
# course has to have read the file, and asking core is not the same as core
# having been told.
has_in "the logbook reads the courses file too"    "$ST" 'require("courses-file").merge'

# The Cabinet. Trophies are recorded where the stage is already being written
# down, and judged against the history as it stood BEFORE this run, because otherwise
# "recalling a binding you previously missed" is satisfied by the miss in this
# very stage, and Cache Hit fires on every requeue.
has "trophies are recorded"                        "trophies.record(cabinet,"
has "the cabinet is persisted"                     "write_cabinet(cabinet)"
has "trophies are judged against prior facts"      "local facts = prior_facts"
has "prior play is parsed at arm time"             "prior_facts = core.history_facts("
# Hyprland caps how long ONE timer callback may run. Parsing the history on
# completion blew that budget once the file grew past a couple of dozen stages,
# the callback was killed, and the results screen never reached the display.
# so a finished stage left the overlay stuck on the last answer. Nothing in the
# completion path may read or parse the history again.
if grep -nE "core\.(previously_missed|best_course_average|personal_bests|parse_history)\(" "$E" \
   | grep -v "history_facts" | grep -q .; then
  _fail "the completion path does not re-parse history" "facts precomputed at arm" \
        "$(grep -nE 'core\.(previously_missed|best_course_average|personal_bests)\(' "$E" | head -1)"
else
  _pass "the completion path does not re-parse history"
fi
has "the cabinet lives in XDG state"               'CABINET_FILE = STATE_DIR .. "/omashift/trophies.json"'
# A corrupt cabinet must cost trophies, never the session.
has "a bad cabinet cannot throw"                   "pcall(core.parse_cabinet"
says "a first earn is announced"                   "TROPHY"

# The start screen advertises when the co-driver will speak, and that number
# must come from the preset rather than a shell-side default. It said 2s while
# medium was actually 4s, because the display kept a default from before the
# presets moved into Lua. Found by launching it, not by the suite.
has "the preview resolves its own timing"          "core.difficulty(difficulty).hint_mods"
has "the preview takes the raw value"              "function _G.omashift_preview(notes, mods_ms, course, difficulty)"

# The ladder breakdown, now on the single results page.
has "the results page shows the ladder"            "core.tier_counts(stage)"

# The terminal renderer is gone (2026-08-26). It shipped first and made the game
# playable while the overlay was being built, then became a window to manage for
# a display nobody looked at. Its assertions went with it; what they protected
# (the display must not read input, must not drive the engine) is now protected
# by the file simply not existing.
assert_eq "the terminal renderer is really gone" 0 \
  "$(ls ../bin/omashift-display 2>/dev/null | wc -l)"
# Comment-stripped: the note above this explains the removal by naming the very
# things it removed, and an unstripped grep flags its own explanation. Fifth time.
assert_eq "and the launcher no longer opens one" 0 \
  "$(( $(code_count "$L" 'xdg-terminal-exec') + $(code_count "$L" 'omashift-display') + $(code_count "$L" 'DISPLAY_PID') ))"

# THE LAUNCHER MUST LOAD THE ENGINE, and must not swallow the answer.
#
# This line was deleted by accident with the terminal display, and because its
# reply went to /dev/null nothing noticed: the launcher published against
# whatever engine a previous session had left loaded, and the game never started
# with no error anywhere. A silenced eval is a silenced failure.
has_in "the launcher loads the engine"       "$L" "dofile('\$BASE/lib/engine.lua')"
has_in "and refuses to continue if it fails" "$L" 'the engine did not load'
assert_eq "the engine load is not silenced" 0 \
  "$(code_count "$L" "engine.lua')\" >/dev/null")"

has_in "the launcher fires an armed stage"   "$L" "fire_if_armed"
has_in "arming writes a marker"              "$L" '> "$ARMED"'
# The arm holds OPTIONS, not a composed call, so a menu can change a setting
# without knowing a word of Lua. Firing composes at the last moment from
# whatever is on disk.
has_in "the arm stores options"              "$L" "write_arm() {"
has_in "and firing composes from them"       "$L" "_G.omashift_start({ length = \$a_length"
# Read, never sourced: this file is written by a menu too, and sourcing it would
# execute whatever ended up in it.
assert_eq "the arm file is never sourced" 0 "$(grep -cE '^\s*(\.|source) "\$ARMED"' "$L")"
# A length that is not a number would reach the engine as Lua and run there.
has_in "the length is validated as a number" "$L" '[[ $a_length =~ ^[0-9]+$ ]]'
has_in "and the course as a plain name"      "$L" '[[ $a_course =~ ^[a-z0-9-]*$ ]]'
has_in "firing clears the marker"            "$L" "disarm"
has_in "an abandoned arm goes stale"         "$L" "ARM_MAX_AGE"
# An engine unloaded since the arm would leave a marker that fails silently and
# reads as a dead key, so firing is confirmed against the submap.
has_in "firing is verified against game mode" "$L" 'hyprctl submap 2>/dev/null) == omashift'
# Nothing may add a global binding for the gate: that is the design being
# rejected, because getting it wrong costs the player their keyboard.
if grep -qE 'hl\.bind\(' "$L"; then
  _fail "the gate adds no global binding" "no hl.bind in the launcher" "one is back"
else
  _pass "the gate adds no global binding"
fi
# Engine errors must be surfaced. Throwing them away is what made a hard failure
# look exactly like a game waiting patiently for a keypress. The start call moved
# to the launcher, so the requirement moved with it.
has_in "the launcher keeps the engine's reply" "$L" 'reply=$(hyprctl eval "$start" 2>&1)'
has_in "...and shows it when a start fails"    "$L" "engine said: \$reply"

# The engine must NOT pass a fixed requeue gap. It used to hand over
# LEARNING_STEPS[1], so a missed note always came back as the second prompt
# after it, predictable enough that you brace for it instead of recalling.
if grep -qF 'core.requeue(stage, missed, core.LEARNING_STEPS[1])' "$E"; then
  _fail "the requeue distance is not fixed" "core.requeue(stage, missed)" "a fixed gap is back"
else
  _pass "the requeue distance is not fixed"
fi
has "the engine lets core pick the gap"            "core.requeue(stage, missed)"

# Speed is the racing-native reading of a reaction time, and it belongs on the
# screens a driver actually looks at.
has "the result line shows speed"                  "core.speed_kmh(result.reaction_ms)"
has "splits show speed"                            "core.speed_kmh(sp.average_ms)"
says "the summary shows average speed"             "avg speed"
has "the results page shows top speed"             "s.top_kmh"

# One page, no timed swap. The summary used to be replaced after 3.5s by a
# telemetry screen, so the numbers worth sitting with were the ones that
# vanished, and a keypress cannot advance it, because hand_back() has already
# released the submap by then.
if grep -qF 'show_telemetry' "$E"; then
  _fail "the results page is not swapped out on a timer" "one page" "a second screen is back"
else
  _pass "the results page is not swapped out on a timer"
fi
# Milliseconds are gone from the screens. Gaps to the ghost stay, in SECONDS,
# which is how motorsport has always expressed them.
if grep -qE '%d ?ms|%\.0f ms' "$E"; then
  _fail "no millisecond readouts remain" "speed, or seconds for gaps" "an ms format is back"
else
  _pass "no millisecond readouts remain"
fi

# TWO RENDERINGS, BOTH WANTED. A JSON publish for the overlay and the same
# screen as text.
#
# The text looks like a leftover of the retired terminal display and is not: the
# offline suite reads exactly that file, which is how test/fixtures/screens/*.txt
# is captured and compared, and it is the only way this project can assert what
# a screen SAYS rather than what it carries. Deleting the write left twelve
# assertions with nothing to read, which is how the mistake was found.
has "structured state is published"                "local function publish(model)"
has "a serializer fault cannot kill a stage"       "pcall(core.to_json, model)"
has "a failed publish says so"                     "serialize failed for screen="
has "the text display still gets written"          "local function render(lines)"
# The merge: text is DERIVED from the model, never authored beside it. If a
# render call ever comes back alongside a publish, the two can drift again.
has "one call draws a screen"                      "local function show(model)"
has "and the text comes from the model"            "render(screens.render(model))"
has "every in-play screen carries the HUD block"   "local function stage_model()"
# Nine screens: ready, countdown x2, prompt, result, results, released x2,
# empty_course. A screen that stops publishing goes dark in QML while looking
# perfectly fine in the terminal, which is the failure worth guarding.
published=$(grep -c 'show {' "$E")
assert_ge "every screen publishes" 9 "$published"

# There must be exactly ONE place that writes a screen. Nineteen call sites
# hand-kept in sync is the thing the merge removed; a second one growing back is
# the thing that would undo it.
assert_eq "publish is called from exactly one place" 1 "$(grep -c '^  publish(model)$' "$E")"
assert_eq "render is called from exactly one place" 1 "$(grep -c '^  render(screens.render(model))$' "$E")"
assert_eq "no screen text is left in the engine" 0 "$(grep -c '^\s*render {' "$E")"

# The model keys each screen depends on. The formatter reads ONLY the model, so
# a key renamed on the engine side turns into a line that quietly disappears
# rather than an error. Fault injection found this: renaming ghost_gap_s left the
# whole suite green, because the captured stages have no ghost to show.
for key in launch_key retire_key ghost_kmh speed_kmh pressed_was requeues away; do
  has "the engine publishes $key" "$key ="
done

# ghost_gap_s is published by BOTH end-of-note and end-of-stage screens, so a
# bare name grep survives renaming one of them. Fault injection caught exactly
# that: renaming it in show_results left the suite green because show_result
# still mentioned it. Scope each one to its own function.
body "the per-note screen publishes the ghost gap" \
  "local function show_result(result)" "ghost_gap_s ="
body "the end-of-stage screen publishes the ghost gap" \
  "local function show_results()" "ghost_gap_s ="

# Every ghost gap is SIGNED. "+0.52" against "-0.52" is the entire reading, and
# an unsigned number makes you work out which side of the ghost you are on.
# Three places show one: a new best, a lost note, and the stage summary.
assert_eq "every ghost gap is signed" 3 "$(grep -c '%+\.2f' "$S")"

# Everything the engine dofiles out of BASE must be staged by EVERY caller that
# builds one: the launcher, the live smoke suite, and the offline sandbox. Miss
# one and the engine dies at load in that context alone, which is how adding
# screens.lua broke ./test/smoke while all 678 offline assertions stayed green.
# Deliberately a bare name match rather than a cp pattern: inventory.lua is
# GENERATED by omashift-inventory, not copied, so anything stricter fails on it.
# The property worth pinning is only that each stager mentions each module at
# all, which is enough to fail when a new one is added and a stager is forgotten.
#
# THE LAUNCHER IS NO LONGER CHECKED THIS WAY, and that is the point: it copies
# lib/*.lua now, so no module name appears in it at all. Naming them one at a
# time is exactly what let scene.lua go unstaged, and this loop could not have
# caught that either, because scene.lua is `require`d rather than `dofile`d.
# The glob, and the require check below it, replace this for the launcher.
for mod in $(sed -n 's|^local [a-z_]* = dofile(BASE \.\. "/lib/\([a-z_]*\.lua\)")|\1|p' "$E"); do
  assert_ge "the offline sandbox stages $mod" 1 "$(grep -c "$mod" ./hl-stub.lua)"
done

# Both stagers copy the library whole. Neither can be forgotten when a module
# is added, which is the only property that actually mattered here.
has_in "the smoke suite stages the whole library" ./smoke "cp ../lib/*.lua"

# THE CABINET. The reading lives in lib/cabinet.lua and the text in screens.lua,
# so the terminal listing and the overlay cannot disagree about what is won. A
# second implementation of the rules is the thing this arrangement exists to
# prevent, since the trophy case used to be computed and formatted in one pass
# inside a bash heredoc.
has_in "the cabinet reading is a module"       "$CB" 'local C = require("cabinet")'
has_in "and the text comes from screens.lua"   "$CB" 'local screens = require("screens")'
assert_eq "no second implementation in the script" 0 "$(grep -c 'CLASS_ORDER' "$CB")"
has_in "--visual publishes to the state file"  "$CB" '--visual'
# The model is built, then told where ESC goes, then serialised. Same model the
# engine publishes, so the overlay needs no special case for it.
has_in "and builds the same model the engine writes" "$CB" "local model = C.model(saved, courses)"
has_in "and serialises it the same way"              "$CB" "core.to_json(model)"

# The overlay renders it, and it is dismissible like every other end screen: the
# cabinet is something you read and then close, not something a stage drives.
has_in "the overlay has a cabinet view"        "$Q" 'visible: view === "cabinet"'
has_in "and the cabinet is dismissible"        "$Q" '"empty_course", "cabinet"'

# THE LOGBOOK. Same arrangement as the cabinet directly above, and it has to
# stay that way: lib/stats.lua owns the reading, screens.lua owns the text, and
# the overlay reads the same model. The alternative is a screen that tells the
# player they are improving while `omashift-stats` says otherwise, which is
# worse than having no screen.
has_in "the logbook reading is a module"       "$ST" 'local stats = require("stats")'
has_in "--visual publishes to the state file"  "$ST" '--visual'
has_in "and builds one model"                  "$ST" "local model = stats.model(text)"
has_in "and serialises it the same way"        "$ST" "core.to_json(model)"
# Written through a temp file and renamed. The overlay watches this path, and a
# reader that catches a half-written document draws a broken screen.
#
# THROUGH THE SHARED WRITER, not a second copy of it. This file used to stage
# through a fixed <path>.tmp of its own, which is the symlink hazard the
# marketplace security review found in the engine, sitting here unnoticed
# because nobody thought to look for the pattern twice.
has_in "the write is atomic"                   "$ST" "runtime.write_atomic(arg[3]"
has_in "and does not hand roll a temp name"    "$ST" 'require("runtime")'
assert_eq "no fixed temp sibling in the logbook" 0 \
  "$(code_count "$ST" '.. ".tmp"')"
# The deep read stays in the terminal. This is the line that stops the visual
# screen from quietly becoming the only one and taking blind spots with it.
has_in "the terminal report survives"          "$ST" "blind spots"

has_in "the overlay has a logbook view"        "$Q" 'visible: view === "stats"'
has_in "and the logbook is dismissible"        "$Q" '"cabinet", "stats"'
has_in "and says how to leave"                 ../qml/Stats.qml "ESC to close"
# ACCURACY IS OVER ANSWERS GIVEN. A retired stage records the prompts it
# PLANNED, so anything dividing by that reads a walk-away as a failed stage.
has_in "accuracy never divides by prompts"     ../lib/stats.lua "pct(correct, answered)"

# THE INSTALLER. The whole safety story of this project is "nothing is written
# to your Hyprland config", which is what makes `hyprctl reload` a complete
# uninstall. An installer that quietly appended a bind line would break that
# promise everywhere it is made, including in the README and in the game itself.
IN=../install
has_in "there is an installer"             "$IN" "XDG_BIN_HOME"
has_in "it links rather than copies"       "$IN" 'ln -sfn "$src" "$target"'
has_in "it can undo itself"                "$IN" "--uninstall"
# Only ever our own link. Someone else's binary of the same name is not ours.
has_in "and only removes its own links"    "$IN" 'readlink -f "$target") == "$HERE/bin/$cmd"'
assert_eq "the installer never writes to a hypr config" 0 \
  "$(grep -cE '>>.*(hypr|bindings)' "$IN")"
# Hyprland can be running with no Lua config at all, and the game is built
# entirely on that API. Finding out at install time beats finding out at launch.
has_in "it checks the Lua config is really there" "$IN" 'hyprctl eval "return 1"'
# EVERYTHING THE GAME CANNOT START WITHOUT. jq reads the keymap into the
# question bank on every launch, and went unchecked for two weeks because it
# is present on every machine this has ever run on. That is the reason to check
# it, not the reason not to.
for tool in hyprctl lua quickshell jq; do
  has_in "install checks for $tool"        "$IN" "check $tool"
done
# Wanted rather than needed: the game plays without python3, and only the
# terminal report and --restore do not.
has_in "and warns about python3 without failing" "$IN" "The game will play"

# IT HAS TO BE FINDABLE. Omarchy's app listing reads .desktop files and there
# was not one, so Omashift appeared nowhere in the menu: the launch chord was
# the only way in, including for whoever installed it and forgot which chord
# they chose.
has_in "the installer writes a desktop entry" "$IN" "omashift.desktop"
# Exec must be ABSOLUTE. ~/.local/bin is not reliably on a desktop session's
# PATH, and a launcher entry that silently does nothing is worse than none.
has_in "with an absolute Exec"                "$IN" 'Exec=$HERE/bin/omashift'
has_in "and the game's own icon"              "$IN" "assets/omashift-icon.svg"
# One main category, or it can be listed twice.
assert_eq "and exactly one main category"  1 "$(grep -c '^Categories=Game;$' "$IN")"
# Removed on uninstall, and only if it is ours.
has_in "uninstall takes the entry with it"    "$IN" "grep -qF \"Exec=\$HERE/bin/omashift\""

# THE README IS THE FRONT DOOR. It used to be the build journal, which is now
# docs/design-log.md. These are the facts a stranger acts on, so they are the
# ones that must not drift from the code.
RM=../README.md
has_in "the readme names the launch chord"  "$RM" "SUPER + ALT + O"
has_in "and the way out of a stage"         "$RM" "SUPER + SHIFT + ESCAPE"
has_in "and the watchdog you can wait for"  "$RM" "ninety second"
has_in "and the install command"            "$RM" "./install"
# The journal is NOT published. It links into a private repo a dozen times and
# carries play data attributed to a person, so the README says it exists and
# says why it is not here, rather than linking at a file a cloner does not have.
assert_eq "the readme does not link the private journal" 0 "$(grep -c 'docs/design-log.md' "$RM")"
# The crash is upstream, fixed, and the guard is what stands between a player
# and it. A known-issues section that omits any of the three is worse than none.
has_in "the readme names the crash"         "$RM" "keybindSetEnabled"
has_in "and the release it is fixed after"  "$RM" "0.56.2"
has_in "and what the guard does about it"   "$RM" "omashift-guide-guard"
has_in "and how thin the machine coverage is" "$RM" "one keymap"
has_in "and calls it untested rather than working" "$RM" "untested rather than broken"
# NOTHING IS ONE WAY. "Delete your entire history" is not an undo, so there is a
# command that lists what is out and one that takes a single action back by
# dropping its SKIP records and nothing else.
has_in "you can see what is out of rotation" "$L" '== "--retired"'
has_in "and take one back"                   "$L" '== "--restore"'
has_in "the restore keeps a copy first"      "$L" 'cp -f "$HIST" "$HIST.bak"'
# Only skips. A restore that dropped answered records would be deleting the
# training data the whole game is built on.
has_in "and only removes skip records"       "$L" 'a.get("outcome") == "skipped"'
# A line the rewriter cannot parse is a line it has no business deleting.
has_in "and never drops a line it cannot read" "$L" "kept.append(raw)"
# And the README tells a player all of it, since none of it is discoverable by
# staring at the screen.
has_in "the readme explains skipping"     "$RM" "omashift --retired"
has_in "and how to undo it"               "$RM" "omashift --restore"
has_in "and that capture is total"        "$RM" "does nothing at all"

# EVERY LAUNCH LEAVES A LINE BEHIND. Run from a keybinding there is no terminal,
# so a failure was reconstructible only from a notification that may or may not
# still be on screen and carries no timestamp. Asked "did it fail, and when",
# nobody could tell.
has_in "there is a launch log"           "$L" 'LOG="$BASE/launch.log"'
has_in "and a way to read it"            "$L" '== "--log"'
has_in "failures are recorded"           "$L" 'log_line "FAILED:'
# Successes too. A log that only records disasters cannot answer "was this the
# run that broke it", and the interesting question is usually the run before.
has_in "and so are the successes"        "$L" 'log_line "engine loaded'
has_in "and stage starts"                "$L" 'log_line "started:'
# A file that grows forever is a different bug.
has_in "the log is bounded"              "$L" "LOG_MAX_LINES"
# Defined next to BASE, above every mode handler that uses it. The first version
# put it three hundred lines below `--log`, which aborted on an unbound
# variable: the same shape as a test helper defined below its first use.
assert_eq "the log is defined before the modes that read it" 1 \
  "$(awk '/^LOG="\$BASE\/launch.log"/{d=NR} /== "--log"/{u=NR} END{print (d && u && d < u) ? 1 : 0}' "$L")"

# ESCAPE ON THE RESULTS GOES BACK TO THE MENU. Finishing a stage and wanting
# another go is the ordinary case, and the only way to act on it was to close
# the game and reach for the launch chord again.
body "the results page says where back goes" "local function show_results()" 'back = "menu"'
# ENTER GOES AGAIN. Wanting another stage is the ordinary thing to want on a
# results page, and routing it through the menu made the core loop cost two
# presses and a screen nobody asked to see.
has_in "enter starts another stage"      "$Q" 'surface.shell.ask("--again")'
# From the results ONLY. On the Cabinet or the Logbook there is nothing to
# repeat, so ENTER falls through and dismisses like any other key.
has_in "and only from the results page"  "$Q" 'surface.view === "results"'
has_in "the launcher can repeat a stage" "$L" '== "--again"'
# `armed` is consumed when a stage starts, so a repeat has to rebuild it.
# Twice: once for --menu and once for --again. Both have to rebuild it, because
# `armed` is consumed the moment a stage starts.
assert_eq "both paths rebuild the armed options" 2 "$(code_count "$L" 'cp -f "$LAST" "$ARMED"')"
# And says so, on both renderings, because the overlay holds the keyboard and
# these are the only keys that do anything at all.
has_in "the overlay lists all three keys" "$Q" "ENTER goes again"
has_in "and so do the text screens"       "$S" "ENTER goes again"
# `armed` is consumed when a stage starts, so the menu has to be rebuilt from
# somewhere. Without this it would come back having forgotten the course you
# just played.
has_in "the options outlive the stage"   "$L" 'LAST="$BASE/last"'
has_in "and the menu rebuilds from them" "$L" 'cp -f "$LAST" "$ARMED"'
# The timeout still LEAVES. Returning to a keyboard-holding menu on a machine
# somebody has walked away from is the opposite of what the timeout is for.
has_in "but the timeout still leaves"    "$SH" "function leave()"

# THE PATRON CREDIT, AND THE RESTRAINT AROUND IT.
#
# The rule is the project's own, written when using the mark's four dots as the
# modifier HUD was rejected: a FUNCTIONAL element carrying a company mark is
# product placement rather than homage. These assertions are what keep the
# credit to one non-functional element on one screen, because "we agreed to keep
# it subtle" is not a thing a repository can check.
FM=../qml/FourMark.qml
has_in "the mark is drawn, not shipped"    "$FM" 'color: "#1FCFCB"'
# Every number is from the vector source, so the rendering is exact rather than
# approximate: disc r=65, dots r=11.8, three stacked right and one left.
has_in "from the source geometry"          "$FM" "11.8 * k"
has_in "with four dots"                    "$FM" "[[8.3, -32.1], [8.3, 0], [-23.7, 0], [8.3, 32.1]]"

# ONCE, ON ONE SCREEN. Not on the results page, not on the Cabinet, not on the
# Logbook: those are the screens people screenshot and they belong to the
# player.
assert_eq "the credit appears exactly once" 1 "$(grep -c 'FourMark {' "$Q")"
assert_eq "and nowhere in the trophy case" 0 "$(grep -c 'FourMark' ../qml/Cabinet.qml)"
assert_eq "nor in the logbook"             0 "$(grep -c 'FourMark' ../qml/Stats.qml)"
# The teal is nearly the complement of this game's magenta. One deliberate cold
# note against a warm scene reads as livery; ten reads as a clash.
assert_eq "the teal is decal only"         0 "$(cat "$Q" ../qml/Theme.qml | grep -c '1FCFCB')"
# "Patron" and not "sponsored by". Four did not buy the placement, and the word
# that describes it accurately is the one this project already uses.
has_in "it says patron, not sponsor"       "$Q" 'text: "patron"'
assert_eq "and never claims sponsorship"   0 "$(code_count "$Q" "sponsored by")"
assert_eq "and the readme does not either"  0 "$(grep -ci 'sponsored by' "$RM")"
has_in "the readme says who and why"       "$RM" "## Patron"
# And SHOWS the mark, generated from the same geometry as the one in the game,
# so the README and the loading frame cannot end up displaying two marks.
has_in "and shows the mark"                "$RM" 'assets/four-mark.svg'
has_in "which is generated too"            ../assets/make-logo.py "def four_mark():"
has_in "from the source geometry"          ../assets/make-logo.py "FOUR_DOTS = ((8.3, -32.1)"
# One set of numbers, two renderings. The QML and the SVG have to agree.
has_in "and the game draws the same dots"  ../qml/FourMark.qml "[[8.3, -32.1], [8.3, 0], [-23.7, 0], [8.3, 32.1]]"
has_in "and that it is easy to remove"     "$RM" "meant to be easy to"
# Single quotes: the needle contains backticks, and inside double quotes bash
# runs them. The first version of this line tried to execute PRINT, and the
# guard above caught it as an assertion that never ran.
has_in "and the readme explains the key" "$RM" "saves a picture"

# THE ESCAPE HATCH IS SHOWN, not just named. The README told you the file exists
# and never showed one, which is the half that leaves you guessing at the shape.
# Cockpit is the worked example: a real course, in the author's own
# courses.lua, and deliberately NOT in the table below.
has_in "the readme shows a courses.lua"   "$RM" ".config/omashift/courses.lua"
has_in "with a course in it"              "$RM" '["cockpit"] = {'
has_in "and says patterns match text"     "$RM" "matched against binding **descriptions**"

# THE COURSE TABLE PROMISES ONLY WHAT SHIPS. It listed Cockpit, which is the
# EXAMPLE of a course you write yourself and lives in one person's courses.lua.
# Advertising it as part of the game is a promise the download does not keep.
missing_course=$(lua -e '
  package.path = "../lib/?.lua;" .. package.path
  local core = require("core")
  local labels = {}
  for name, c in pairs(core.COURSES) do labels[c.label or name] = true end
  local bad = {}
  local inTable = false
  for line in io.lines("../README.md") do
    if line:match("^| Course |") then inTable = true
    elseif inTable and not line:match("^|") then inTable = false
    elseif inTable then
      local label = line:match("^| ([^|]-) |")
      if label and label ~= "---" and not labels[label] then
        bad[#bad + 1] = label
      end
    end
  end
  io.write(table.concat(bad, ", "))')
assert_eq "the course table lists only courses that ship" "" "$missing_course"

# The patron link is the one place this README sends traffic anywhere.
assert_eq "both patron links carry the campaign tag" 2 \
  "$(grep -c 'paywithfour.com/?utm_source=omashift' "$RM")"
assert_eq "and none of them is left untagged" 0 \
  "$(grep -c 'paywithfour\.com[^/]' "$RM")"
# The domain is registered and does not resolve. A dead link in a README ships
# once and stays for a year.
assert_eq "and does not link the domain yet" 0 "$(grep -c 'https://omashift.com' "$RM")"

# THE LOGO HAS TO BE VISIBLE ON BOTH THEMES. omashift-logo.svg is dark ink for
# light backgrounds, and alone it is very nearly invisible on GitHub's dark
# theme, which a lot of people are reading in. An editing pass replaced the
# <picture> element with a plain image and nothing noticed.
has_in "the logo picks a variant per theme" "$RM" "prefers-color-scheme: dark"
has_in "and names the dark-background one"  "$RM" "omashift-logo-dark.svg"
# THE IMAGES THE LAUNCH NEEDS. This counted four `<!-- SCREENSHOT:` markers, back
# when all four were plans. Four were taken on 2026-08-27 and are now real
# references, so counting markers counts what is MISSING rather than what is
# wanted, and each shipped image is asserted by path instead.
#
# BY PATH, and under assets/, because `publish` withholds `docs` whole. A README
# pointing at docs/img/ passes every check in this suite and then renders as five
# broken images on the public repo, where nobody is running the suite.
has_in "the readme shows the menu"        "$RM" "assets/img/menu-track-day.png"
has_in "and the results page"             "$RM" "assets/img/results.png"
has_in "and the cabinet"                  "$RM" "assets/img/cabinet.png"
has_in "and the logbook"                  "$RM" "assets/img/logbook.png"
has_in "and a second course's backdrop"   "$RM" "assets/img/menu-blind-spots.png"
# THE LAST ONE, and it was the hard one: mid-stage the submap owns the keymap and
# there is no key left for the game to offer, so P cannot take it. A delayed
# omashift-snapshot did, on the third attempt, which is why the plan now says to
# arm several rather than betting on one shutter.
has_in "and a pace note mid-stage"        "$RM" "assets/img/stage.png"
# A reference is not an image. These are the files themselves.
assert_eq "the images are in the tree" 6 "$(find ../assets/img -name '*.png' | wc -l)"
# NOTHING IS LEFT MARKED. Every planned screenshot has been taken, so a marker
# reappearing means one was pulled back out and is now missing from the launch.
assert_eq "no screenshot is still a plan" 0 "$(grep -c '<!-- SCREENSHOT:' "$RM")"
# ALL SIX ARE THE SAME SIZE. They sit one after another in the README, and one
# arriving at native 3440x1440 renders at a different scale from its neighbors,
# which is how the Logbook shot first came in.
odd_size=$(identify -format '%wx%h\n' ../assets/img/*.png 2>/dev/null | sort -u | grep -cv '^2064x864$')
assert_eq "and all one size" 0 "${odd_size:-0}"

# ONE SEPARATOR, TWO READERS. The terminal legend is "MILESTONES: once, ever",
# and the Cabinet overlay shows the class alone by splitting that string. The
# separator is therefore a contract between lib/cabinet.lua and Cabinet.qml, and
# it was very nearly broken silently: the em dash sweep changed the label and the
# split kept looking for the old character, which would have put the whole legend
# on a badge. Nothing offline runs QML, so no other assertion could have caught
# it.
has_in "the cabinet legend uses a colon"  ../lib/cabinet.lua 'milestone  = "MILESTONES: once, ever"'
has_in "and the overlay splits on one"    ../qml/Cabinet.qml 'modelData.label.split(": ")[0]'

# NO EM DASHES AND NO EN DASHES, ANYWHERE. John's rule, and it is not only for
# prose that gets published: it covers code comments, which is where 221 of them
# were hiding. Split the sentence rather than swapping the character for a
# hyphen, because the point is the shorter sentence and not the punctuation.
#
# test-cabinet.lua has enforced this on trophy notes since the notes were
# written. That is the tell: the rule was known and checked in exactly one
# place, so everywhere else drifted for as long as the repo has existed.
#
# The needles are byte escapes, for two reasons. The characters would otherwise
# put the thing being banned into the file that bans it, and two of them were
# hiding inside Lua strings as a decimal escape triple, which no search for the
# character itself would ever have found.
# -I SKIPS BINARY FILES, and it is load bearing. ../assets holds screenshots,
# and a PNG's compressed bytes will eventually contain \xe2\x80\x94 by chance:
# assets/screenshot-cabinet.png did, twice, and failed a rule about prose on a
# file that has none. Nothing textual is skipped by -I, so the rule itself is
# unchanged.
dashes=$(grep -rIc "$(printf '\xe2\x80\x94')\|$(printf '\xe2\x80\x93')\|226.128.14[68]" \
  ../lib ../qml ../bin ../test ../assets ../install ../README.md ../manifest.json ../docs 2>/dev/null \
  | awk -F: '{ n += $2 } END { print n + 0 }')
assert_eq "no em dashes or en dashes anywhere in the tree" 0 "$dashes"

# US ENGLISH, BECAUSE THE AUTHOR IS AMERICAN.
#
# Fifty British spellings were in here: the license section heading, and the
# British forms of color, center, behavior, honor, defense and artifact through
# the comments, with a trophy table named in the British spelling of catalog.
# Fluent, consistent, and somebody else's voice. The same failure as a launch
# post that measures two weeks in a word no American says.
#
# The needles carry a bracket so this line does not match itself. A spell check
# that fails on its own definition is not a spell check.
briticisms=$(grep -rnI -io \
  "col[o]ur\|behavi[o]ur\|hon[o]ur\|rasteri[s]\|recogni[s]e\|cent[r]e\|licen[c]e\|artef[a]ct\|neighb[o]ur\|label[l]ed\|catalo[g]ue\|whil[s]t\|among[s]t\|fortnigh[t]" \
  ../lib ../qml ../bin ../test ../assets ../install ../README.md ../manifest.json ../docs 2>/dev/null | wc -l)
assert_eq "the public tree is in US English" 0 "$briticisms"

# ATTRACT MODE. The front screen is the one place in the game where nothing is
# being timed and the player's own keybindings are still live, so it is the one
# place a logo can move without costing anybody anything.
has_in "the front screen carries the wordmark" "$Q" "Wordmark {"
# The loading frame too. It drew nothing at all, so the overlay came up on a
# bare backdrop while the keymap was read, and a blank wallpaper is
# indistinguishable from a game that failed to start.
has_in "and so does the loading frame"         "$Q" 'visible: view === "loaded"'
assert_ge "the wordmark appears on both"     2 "$(grep -c 'Wordmark {' "$Q")"
has_in "and it is generated, not drawn twice"  ../qml/Wordmark.qml "GENERATED by assets/make-logo.py"

# NOTHING SHIPS A PATH FROM THIS MACHINE. The public tree is copied out of a
# private repo, so a stray `~/repos/<something>/...` in a comment travels with
# it. One did, in the header of shell.qml, and only a publish rehearsal found
# it.
for f in "$E" "$S" "$Q" "$SH" "$L" "$CB" "$ST" "$IN" "$RM" ../lib/scene.lua ../lib/stats.lua; do
  # The tilde is a REGEX and must not expand: the whole point is to catch a
  # literal `~/repos/` typed into a file.
  # shellcheck disable=SC2088
  assert_eq "no private path in $(basename "$f")" 0 \
    "$(grep -cE '~/repos/|/home/[a-z]+/|/Users/' "$f")"
done

# AND NOTHING NAMES THE REPO IT CAME OUT OF, not even in a comment. The path
# check above catches the realistic leak; this catches the bare word, which a
# sentence explaining where something used to live would carry through.
#
# The name is computed rather than written, so this file does not reintroduce
# the very thing it is checking for. Only meaningful in the private tree: in a
# published one the parent directory is whatever the cloner called it.
# Asked of git rather than counted in `..`, because counting got it wrong: from
# test/ the parent-of-parent is `tools`, and every file mentioning "development
# tools" failed a check about a repository name.
if [[ -r ../publish ]] && private_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  private_repo=$(basename "$private_root")
  named=""
  for f in "$E" "$S" "$Q" "$SH" "$L" "$CB" "$ST" "$IN" "$RM" ../publish \
           ../lib/*.lua ../qml/*.qml ../bin/* ./*.sh; do
    [[ -f $f ]] || continue
    grep -qiF -- "$private_repo" "$f" && named="$named $(basename "$f")"
  done
  assert_eq "no shipping file names the repo it came from" "" "$named"
fi

# THE ALLOW LIST COVERS EVERYTHING. ./publish copies a named set into the public
# tree, which is the right shape precisely because the failure mode of an ignore
# list is silence: add a file, forget to list it, and it ships. That only holds
# if nothing can sit outside both lists, so this is the assertion that keeps the
# allow list honest as the tree grows.
# ./publish is itself withheld, so in a PUBLISHED tree it is absent and these
# four assertions have nothing to check. That is the correct state rather than a
# failure: the suite has to pass for somebody who cloned the public repo, and
# the first rehearsal of this had them failing there for exactly that reason.
PUB=../publish
if [[ -r $PUB ]]; then
  missing=""
  for path in ../*; do
    entry=$(basename "$path")
    grep -qF "  $entry" "$PUB" || grep -qF "[$entry]" "$PUB" || missing="$missing $entry"
  done
  assert_eq "every file is published or withheld on purpose" "" "$missing"
  has_in "and the journal is withheld by name" "$PUB" "[docs/design-log.md]="
  has_in "with the reason attached"            "$PUB" "play data by name"
  # Regenerated on the way out, so a published tree can never carry a wordmark
  # that disagrees with the script that makes it.
  has_in "the wordmark regenerates on publish" "$PUB" 'make-logo.py'
  # The linter configs travel too. They are dotfiles, so the allow-list audit
  # above skips them and nothing would have noticed them missing: a contributor
  # would get the suite without the configs that make two of its checks usable.
  has_in "the luacheck config ships"          "$PUB" ".luacheckrc"
  has_in "and the ruff config"                "$PUB" ".ruff.toml"
else
  _pass "this is a published tree, so there is no allow list to check"
fi

# STAGING. The launcher copies the library somewhere the compositor can read it,
# and it used to copy a hand-written list of four files. lib/scene.lua was added
# and was not on the list, so the engine loaded, hit require("scene") and died,
# and because the launcher is normally run from a keybinding the error went to a
# stderr nobody was reading. The symptom was a key that did nothing.
#
# The glob widened from *.lua to * when lib/runtime.sh arrived: the guard is
# sourced from the staged copy at $BASE, so a Lua-only glob left it behind in
# exactly the layout where nothing could fall back to the repo.
has_in "the launcher stages the whole library" "$L" 'cp "$HERE"/lib/*'
assert_eq "and does not name files one at a time" 0 \
  "$(grep -cE 'cp "\$HERE/lib/[a-z-]+\.(lua|sh)"' "$L")"

# And the check that would have caught it whatever the staging looked like:
# every module anything in lib/ asks for has to be a file in lib/. inventory.lua
# is the one exception, generated at launch from the live keymap.
missing=""
for m in $(grep -ho 'require("[a-z_]*")' ../lib/*.lua | sed 's/require("\(.*\)")/\1/' | sort -u); do
  [[ $m == inventory ]] && continue
  [[ -r "../lib/$m.lua" ]] || missing="$missing $m"
done
assert_eq "every module the library requires is in lib/" "" "$missing"

# EVERY hyprctl CAPTURE SURVIVES A FAILURE. Under `set -e` a command
# substitution that exits non-zero aborts the script at the assignment, so the
# check on the next line never runs. hyprctl exits 7 on a Lua error, which is
# precisely the case each of those checks was written for, so all of them were
# dead code exactly when they were needed. The symptom was a launcher that
# stopped with no output at all.
unguarded=$(grep -nE '=\$\(hyprctl' "$L" | grep -v '|| true' | grep -vE '\\$' | wc -l)
assert_eq "every hyprctl capture tolerates a failure" 0 "$unguarded"

# FAILURE HAS TO BE VISIBLE. A keybinding has no terminal, so a message on
# stderr is a message to nobody, and a failed launch is indistinguishable from
# a binding that does not exist.
has_in "a failed launch says so"           "$L" "die() {"
has_in "and notifies when there is no terminal" "$L" 'if [[ ! -t 2 ]] && command -v notify-send'
has_in "and the engine load uses it"       "$L" 'die "the engine did not load"'

# THE BACKDROP NEVER SHOWS THE DESKTOP.
#
# Changing course changes the wallpaper, and a wallpaper is decoded
# asynchronously: for a frame or two nothing was painted and the desktop showed
# through the middle of an open menu. Two defenses, because one is not enough.
# The crossfade keeps the old picture up until the new one is ready, and the
# opaque floor means the worst case is a dark panel rather than someone's
# desktop.
has_in "there is an opaque floor under everything" "$Q" "color: Qt.rgba(0.06, 0.03, 0.08, 1)"
has_in "the backdrop crossfades"                   "$Q" "property bool frontIsA"
has_in "and only swaps once the new picture is ready" "$Q" "if (layer.status !== Image.Ready) return;"
# The swap is guarded on the path too: two quick course changes must not let a
# stale decode win the race and paint the wrong wallpaper.
has_in "and ignores a decode that is no longer wanted" "$Q" 'layer.source.toString() !== wanted'
# Two layers, not one. One image has to blank itself to load the next, which is
# the flicker. (An earlier version of this assertion counted `visible:
# !!surface.scene` and failed on the crossfade container and the scrim, which
# both use it correctly: it was checking a coincidence, not the property.)
assert_eq "the backdrop has two layers to fade between" 2 "$(grep -c 'id: layer[AB]$' "$Q")"

# THE DRAWN SKY IS STILL A CIRCLE.
#
# The fallback backdrop, for a machine without the course's theme, is a striped
# sun drawn from shapes. Its cuts have been wrong twice, in opposite directions,
# and both times only a render showed it. As full-width rectangles they hung out
# past the disc, which narrows toward the bottom while they thicken, and the sun
# squared off where it meets the horizon. Sized as chords they stayed inside,
# but a chord is straight across a curve, so lit slivers of the disc stood
# either side of every cut and the bottom became a stack of steps.
#
# A rectangle has no curve in it and the cut needs one at both ends, so the band
# clips a sky-colored copy of the disc instead. These assertions pin that
# shape: a cut is the disc, masked, not a rectangle measured against it.
SKY=../qml/Sky.qml
has_in "each cut clips its own band"      "$SKY" "clip: true"
has_in "of a copy of the disc"            "$SKY" "height: sun.height"
has_in "put back where the disc is"       "$SKY" "y: -parent.cutTop"
# NOT a count of `radius: width / 2`. Three things in this file are round for
# unrelated reasons -- the disc, this copy of it, and the dust motes -- so a
# count of the idiom pins a coincidence rather than the shape.
has_in "and it is round like the disc"    "$SKY" "radius: width / 2"
# The numbers, not just the shape. A band outside the disc clips away to
# nothing, and a cut that quietly renders as empty looks exactly like a cut
# somebody decided to remove.
cuts_outside=$(awk '
  # The count belongs to the Repeater the cuts are IN. Taking the first or the
  # last "model:" in the file picks up the dust field instead, which is a
  # coincidence that would pass today and lie later.
  match($0, /model: ([0-9]+)/, m) { pending = m[1] }
  match($0, /cutTop: sun.height \* \(([0-9.]+) \+ index \* ([0-9.]+)\)/, t) {
    t0 = t[1]; ts = t[2]; n = pending
  }
  match($0, /cutHeight: sun.height \* \(([0-9.]+) \+ index \* ([0-9.]+)\)/, h) {
    h0 = h[1]; hs = h[2]
  }
  END {
    if (t0 == "" || h0 == "" || n == "") { print "unreadable"; exit }
    bad = 0
    for (i = 0; i < n; i++) {
      top = t0 + i * ts
      bot = top + h0 + i * hs
      if (top < 0 || bot > 1) bad++
    }
    print bad
  }' "$SKY")
assert_eq "every cut lands inside the disc" 0 "$cuts_outside"

# A KEY BOUND TO NOTHING SAYS SO. The submap replaces every binding while a
# stage runs, so a key outside the question bank is not wrong, it is swallowed.
# A player pressed PrintScreen on its own and got nothing back at all, which is
# indistinguishable from a game that has stopped responding.
has_in "an unbound key is noticed"        "$E" "local unbound = false"
has_in "and told to the screen"           "$E" "unbound = unbound or nil"
has_in "and shown by the overlay"         "$Q" "doc.unbound === true"
has_in "and by the text screens"          "$S" "that key does nothing during a stage"
# NOT "not bound to anything", which is what it said first and is usually false.
# Blaming the player's keymap for the game's own capture is a confident, wrong
# explanation, which is worse than the silence it replaced.
assert_eq "and never blames the keymap"   0 "$(code_count "$S" "not bound to anything")"
assert_eq "nor in the overlay"            0 "$(code_count "$Q" "not bound to anything")"
# An auto-repeat is not a new press. Holding a modifier repeats its keycode and
# the modifier set does not change, so without this the game would announce
# "not bound to anything" in the middle of a chord being typed.
has_in "a held key is not pressed twice"  "$E" "local keys_down = {}"
has_in "and an answer cancels the notice" "$E" "unbound_generation = unbound_generation + 1"

# TWO RETURNS PER NOTE, and no more. One was too tight to teach: missing
# something, seeing it again and missing it again is an ordinary way to learn a
# chord. Uncapped it is a loop with no exit.
has_in "the requeue limit is a named constant" ../lib/core.lua "M.REQUEUE_LIMIT = 2"
has_in "and it is enforced"                    ../lib/core.lua "if seen >= M.REQUEUE_LIMIT then return nil end"

# ESCAPE LEAVES, it does not merely hide. Dismissing used to hide the surfaces
# and leave quickshell running with nothing on screen and the engine still
# loaded, which is not what "exit" means to anyone pressing Escape.
has_in "dismissal leaves the app"          "$SH" "function leave()"
has_in "and quits the overlay"             "$SH" "Qt.quit()"
has_in "and stops the game behind it"      "$SH" 'Quickshell.execDetached([bin, "--stop"])'
has_in "wired to the shared dismissal"     "$SH" "if (sharedDismissal.done) shellRoot.leave();"
# The callback path is told, not guessed: a renderer cannot know where the game
# lives, and working it out from its own path is the same class of bug as
# hardcoding a chord into a formatter.
has_in "the launcher tells it where the game is"  "$L"  "OMASHIFT_BIN="
has_in "and so does --visual"                     "$CB" "OMASHIFT_BIN="

# EXACTLY ONE SURFACE ASKS FOR THE KEYBOARD. Every monitor gets a surface, and
# two of them demanding the same keyboard is a fight the compositor has to
# settle, which drops keys.
has_in "only one surface owns the keyboard" "$SH" "focusOwner: modelData === Quickshell.screens[0]"
# The MENU takes the keyboard too, so the condition covers both. It is listed
# separately from endScreen because dismissing the menu is only one of the things
# its keys can do.
has_in "and the surface honors that"       "$Q"  "surface.visible && (surface.endScreen || surface.menuScreen) && surface.focusOwner"
has_in "the welcome screen is a menu"       "$Q"  'readonly property bool menuScreen: view === "ready"'
# Focus is claimed, not awaited: the compositor grants it asynchronously after
# the surface maps, and an Escape pressed in that gap lands nowhere.
has_in "focus is claimed explicitly"        "$Q"  "forceActiveFocus()"

# A SCREEN THAT TAKES THE KEYBOARD MUST SAY HOW TO GIVE IT BACK.
#
# Exclusive focus on this surface swallows Hyprland's own shortcuts: with the
# Cabinet up, SUPER+RETURN opens nothing and SUPER+W closes nothing. Escape is
# the only key that works. Verified by pressing them.
#
# So the overlay must not advertise a chord that cannot fire, and must name the
# one that can. The results footer used to say "your keys are back" and point at
# SUPER+ALT+O, both false while it held focus.
assert_eq "the overlay never claims the keys are back" 0 "$(code_count "$Q" 'your keys are back')"
has_in "the results screen names the key that works" "$Q" "ESC back to the menu"

# AND THE SCREENSHOT KEY, on the three screens worth keeping. Exclusive focus
# swallows the player's own screenshot binding along with everything else, so
# the Cabinet and the Logbook, the two screens this game was built to be
# screenshotted from, were the two screens where a screenshot was impossible.
# P IS THE ADVERTISED KEY, and PRINT still works for anyone who has it.
# Plenty of keyboards do not: a 75% or 84-key board puts PrintScreen on a
# function layer or leaves it out, and a Mac-oriented one may not send the
# keysym in any layer. Depending on it meant the two screens this game exists to
# be screenshotted from could not be screenshotted on the author's own keyboard.
has_in "a plain letter saves a picture"    "$Q" "event.key === Qt.Key_P || event.key === Qt.Key_Print"
has_in "and the shell knows how to capture"        "$SH" "function snapshot(label)"
has_in "through a command of its own"              "$SH" 'omashift-snapshot'
has_in "the results page offers it"                "$Q" "P saves a picture"
has_in "so does the trophy case"                   ../qml/Cabinet.qml "P saves a picture"
has_in "and the logbook"                           ../qml/Stats.qml "P saves a picture"
# Not omarchy-capture-screenshot: it freezes the screen and opens a region
# picker, and both fight a fullscreen overlay that already holds the keyboard.
assert_eq "and not through the region picker" 0 \
  "$(code_count ../bin/omashift-snapshot "omarchy-capture-screenshot")"
has_in "a label cannot become a path"              ../bin/omashift-snapshot "tr -cd 'a-zA-Z0-9_-'"
# A STAGE IN PROGRESS CANNOT BE PHOTOGRAPHED BY A KEY, because the submap has
# replaced the keymap and there is no key left to offer. The timer is the only
# way in, and it has to DETACH: a foreground sleep would hold the very terminal
# that has to launch the stage.
has_in "a stage can be captured on a timer"        ../bin/omashift-snapshot '== "--in"'
has_in "the seconds are a number, not a command"   ../bin/omashift-snapshot 'delay =~ ^[0-9]+$'
has_in "and the wait detaches from the terminal"   ../bin/omashift-snapshot 'sleep "$delay"; exec "$self"'
has_in "the readme says how to take that one"      "$RM" "omashift-snapshot --in 15 stage"
# The countdown is NOT drawn: anything on screen before the shutter is in the
# picture, which is the one thing a screenshot tool must not add.
assert_eq "nothing is drawn before the shutter" 0 \
  "$(code_count ../bin/omashift-snapshot 'notify-send.*capturing')"
has_in "and so does the cabinet"                     ../qml/Cabinet.qml "ESC to close"

# THE BACKDROP IS RESOLVED IN THE ENGINE, NOT THE RENDERER. A display building
# the path itself would have to know where Omarchy keeps its themes and could not
# tell whether the file is there: a missing theme would render as a blank
# rectangle with nothing to say why. nil instead means the overlay draws the sky.
# THE BACKDROP. Resolution lives in lib/scene.lua because three producers need
# it: the engine for every in-play screen, and the Cabinet and the Logbook for
# their own. It was a local inside the engine, which is why those two had no
# backdrop and fell through to the drawn sky.
has "the engine resolves the backdrop"   "local function scene_for(course)"
has_in "from the shared resolver"        "$E" 'local scene_lib = require("scene")'
has_in "checking the user theme dir first" ../lib/scene.lua "/omarchy/themes"
has_in "and returning nothing when missing" ../lib/scene.lua "  return nil"
# EVERY SCREEN CARRIES ONE. The screens that did not flashed the drawn sky at
# you on the way into a game that then played over a photograph.
has_in "the first frame has a backdrop"  "$E" 'screen = "loaded", bindings = #inventory, scene ='
has_in "and so do the reading screens"   "$CB" "model.scene = scene.resolve(core.DEFAULT_SCENE, 0)"
has_in "and the logbook too"             "$ST" "model.scene = scene.resolve(core.DEFAULT_SCENE, 0)"
# Zero, not the scene's own. These screens dim the whole surface themselves and
# a second scrim underneath took the picture to a tenth of its brightness.
has_in "a reading screen brings its own dimming" ../lib/scene.lua "override_scrim or scene.scrim"
has_in "the overlay falls back to its sky" "$Q" "visible: !surface.scene"
# The scrim is per course. One value cannot serve a Brueghel and a black moon.
has_in "the scrim comes from the scene"    "$Q" "surface.scene ? surface.scene.scrim : 0.6"

# WRITE THEN RENAME. A reader landing mid-write sees a truncated file, and the
# overlay treats a parse failure as "no game" and goes blank. This was written
# down as a hazard during the render/publish merge and dismissed as moot because
# the display read text, which was wrong even then: the overlay has always parsed
# JSON. It surfaced when menu keys started depending on the parsed screen.
#
# AND THE STAGED NAME IS UNGUESSABLE. It used to be a fixed <path>.tmp sibling
# in a world writable directory, so anyone could plant a symlink there and have
# the engine truncate a file of the player's through it. That is what the
# marketplace security review called release blocking. The write lives in
# lib/runtime.lua now, and these assert the engine still goes through it.
has "screens are written atomically"   "local write_atomic = runtime.write_atomic"
has "and the writer is the shared one" 'local runtime = dofile(BASE .. "/lib/runtime.lua")'
assert_eq "nothing writes the state file in place" 0 \
  "$(code_count "$E" 'io.open(STATE_JSON, "w")')"
assert_eq "nor the text screen"        0 "$(code_count "$E" 'io.open(STATE, "w")')"
assert_eq "and no fixed temp sibling survives" 0 \
  "$(code_count "$E" 'path .. ".tmp"')"

# NONE OF IT IS IN /tmp ANY MORE, which is the other half of the same review.
# A predictable path in a world writable directory is what made the readers
# attackable at all; $XDG_RUNTIME_DIR is 0700 and per user.
#
# code_count, not grep: the comments explaining why the path moved have to be
# allowed to name the path it moved from, or the history goes unwritten to
# satisfy its own assertion.
for f in "$E" "$L" "$ST" ../bin/omashift-cabinet ../bin/omashift-guide-guard \
         ../qml/StateReader.qml ../qml/BarWidget.qml; do
  assert_eq "no /tmp default in $(basename "$f")" 0 \
    "$(code_count "$f" '/tmp/omashift')"
done
has_in "the launcher resolves state through the helper" "$L" \
  'omashift_runtime_path OMASHIFT_STATE_JSON state.json'
has_in "and refuses when the directory fails its checks" "$L" \
  'no private runtime directory'

# THE OVERLAY TREATS THE DOCUMENT AS UNTRUSTED INPUT.
#
# The runtime directory shuts out another user and not another process of
# yours, and nothing on a filesystem closes that. So the display stops trying
# to prove who wrote the document and bounds what an unexpected one can do: a
# screen the engine cannot produce is dropped whole, which keeps its other
# fields from reaching anything downstream too.
SR=../qml/StateReader.qml
has_in "the overlay caps the read before parsing"   "$SR" 'raw.length > root.maxStateBytes'
has_in "and rejects anything that is not an object" "$SR" 'typeof next !== "object"'
has_in "and drops an unknown screen whole"          "$SR" 'root.knownScreens.indexOf'
# The whitelist has to name every screen the engine can publish, or a real one
# gets dropped and the overlay freezes on the screen before it.
for s in loaded ready countdown prompt result results released cabinet stats empty_course; do
  assert_eq "the whitelist knows the $s screen" 1 \
    "$(grep -c "\"$s\"" <<<"$(sed -n '/knownScreens/,/]/p' "$SR")")"
done

# THE CLOCK COMES FROM WHOEVER OWNS THE TIMERS.
#
# Every deferral goes through hl.timer, so reading the clock from somewhere else
# lets the two disagree. Under test they did: virtual timers advanced instantly
# while /proc/uptime crawled, so a reaction time was however long the harness
# took to make two calls. Fast machine 250 km/h, busy machine 0, and the screen
# goldens flaked on whichever it was that second. Hyprland provides no clock, so
# real play still falls through to /proc/uptime and nothing about a stage changes.
has "the clock defers to the timer source" "if type(hl.now_ms) == \"function\" then return hl.now_ms() end"
has_in "and the harness drives it"         ./hl-stub.lua "now_ms = function() return now end,"

# THE MENU'S KEYS. C is Courses, T is Trophies, S is Stats: what the thing is
# called, rather than a mnemonic you have to be told. Arrows change a NUMBER.
has_in "C cycles the course"     "$Q" 'case Qt.Key_C:'
has_in "T opens the trophies"    "$Q" 'case Qt.Key_T:'
has_in "S opens the stats"       "$Q" 'case Qt.Key_S:'
# And every one of them is LISTED. A key the menu answers to but does not show
# is a key nobody presses, which is the exact problem the menu was built to fix.
has_in "the menu lists the stats"  "$Q" 'text: "stats"; color: theme.text'
has_in "and the text menu agrees"  "$S" "S stats"
# SPELLED OUT ON THE MENU. "Pace note" is the rally term and the prompt screen
# uses it in full; abbreviated to "notes" it drifts toward a musical or written
# one, on the screen a new player reads before their first stage.
has_in "the menu says pace notes"  "$S" "pace notes"
has_in "and so does the overlay"   "$Q" '" pace notes"'
assert_eq "with none left abbreviated" 0 "$(code_count "$Q" 'text: "notes')"
has_in "D cycles the difficulty" "$Q" 'case Qt.Key_D:'
has_in "arrows change the count" "$Q" 'case Qt.Key_Up:'
# The course list comes from core, so a course added in courses.lua appears on
# the menu without this script ever learning its name.
has_in "the course list is asked for, not hardcoded" "$L" "core.course_names()"
# AND THE FILE IS READ BEFORE IT IS ASKED. The assertion above passed while `C`
# cycled straight past every course anyone had written for themselves: the list
# was genuinely asked for, from a fresh Lua state that had never opened
# courses.lua. Asked-for and correct are not the same claim.
has_in "and the user's courses are merged first"    "$L" 'require("courses-file").merge'
# Bounded: a stage of nothing is not a stage, and past forty the SM-2 queue is
# re-asking more than it is asking.
has_in "the note count is bounded"  "$L" "(( next < 5 ))  && next=5"

# ONE SURFACE PER MONITOR, ONE DISMISSAL. shell.qml builds a Surface for every
# screen, so anything a surface owns privately falls out of lockstep the moment
# the monitors disagree. That is not hypothetical: each surface owned its own
# `dismissed`, so Escape cleared the monitor it was focused on and left the other
# showing a fullscreen results page over the desktop.
has_in "the shell shares one dismissal flag"   "$SH" "property bool done: false"
has_in "and injects it into every surface"     "$SH" "dismissal: sharedDismissal"
# The id must differ from the property name. `dismissal: dismissal` resolves the
# right-hand side to the property being declared, so every surface received
# `undefined` and every read threw at runtime while qmllint stayed clean.
# Comments stripped first. The line above this in shell.qml EXPLAINS the bug by
# quoting `dismissal: dismissal`, so an unstripped grep flags its own warning and
# fails on correct code. This project has now written that same bug three times
# (see commit 13e025b, "that assertion was flagging its own explanation"), which
# is enough for it to be a rule: an assertion about code greps code, never prose.
# NO PROPERTY MAY BE ASSIGNED FROM ITS OWN NAME, for any property.
#
# `x: x` inside a delegate resolves the right-hand side to the property being
# declared, not to the outer object, so the surface receives `undefined` and
# every read of it throws at runtime while qmllint stays clean. This has now
# happened twice: `dismissal: dismissal`, and then `shell: shell` walked straight
# past an assertion that named only the first one. Match the SHAPE, not the
# instance, or the next one gets through too.
assert_eq "no property is assigned from its own name" 0 \
  "$(grep -v '^[[:space:]]*//' "$SH" | grep -cE '^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*): \1[[:space:]]*$')"
has_in "the surface requires it"               "$Q"  "required property var dismissal"
# Read-only on purpose: a surface that could assign its own copy would silently
# stop sharing, which is the bug in a new costume.
has_in "and cannot own a private copy"         "$Q"  "readonly property bool dismissed: dismissal.done"
assert_eq "no surface-local dismissed flag" 0 "$(grep -c 'property bool dismissed: false' "$Q")"
# Every writer has to write the SHARED flag, or a dismissal reaches one monitor.
assert_eq "nothing writes a private flag" 0 "$(grep -cE 'surface\.dismissed = ' "$Q")"

# The overlay must be RESTARTED, not reused. quickshell reads the QML straight
# from the repo, so a live overlay runs whatever the file said when it started,
# and reusing it means a change to Surface.qml is silently untested.
has_in "the overlay is restarted, not reused" "$L" 'if qml_running; then'
assert_eq "reuse-and-return is gone" 0 "$(grep -c 'qml_running && return 0' "$L")"

# THE STRANDED SUBMAP. A submap left engaged with no live stage captures the
# keyboard, and because the launch chord is itself in the question bank, pressing
# it is answered as a pace note instead of reaching the launcher. The player is
# locked out of the only thing that could rescue them. Found by playing.
# Counted, not matched. The check appears TWICE, once to detect the stranded
# submap and once to confirm the recovery actually released it, so a bare grep is
# satisfied by whichever one survives. Fault injection removed the detection and
# the assertion passed on the recheck.
assert_eq "a stranded submap is detected, and the release confirmed" 2 \
  "$(grep -c 'if \[\[ $(hyprctl submap 2>/dev/null) == omashift \]\]; then' "$L")"
has_in "and the stranded stage is RETIRED, not bare-reset" "$L" '_G.omashift_on_retire()'
has_in "and it gives up rather than arming into a trap" "$L" "could not release the keyboard"

# The recovery has to run BEFORE the arm is fired, or firing into a stuck submap
# is exactly the case that looked like success.
recover_at=$(grep -n 'a previous stage was still holding your keyboard' ../bin/omashift | cut -d: -f1)
fire_at=$(grep -n '^if fire_if_armed; then exit 0; fi' ../bin/omashift | cut -d: -f1)
if [[ -n $recover_at && -n $fire_at ]] && (( recover_at < fire_at )); then
  _pass "the trap is broken before an armed stage is fired"
else
  _fail "the trap is broken before an armed stage is fired" "recovery before fire" \
    "recovery at ${recover_at:-none}, fire at ${fire_at:-none}"
fi

# Firing must verify an EFFECT. Checking the submap is a precondition that a
# stranded session already satisfies, so a fire that did nothing printed "go."
has_in "firing verifies a countdown was published" "$L" '"screen":"countdown"'
assert_eq "and no longer accepts the submap as proof" 0 \
  "$(grep -c 'hyprctl submap 2>/dev/null) == omashift ]] && { disarm' ../bin/omashift)"

# THE WATCHDOG. Taking the keyboard is never allowed to be permanent, and the
# per-prompt idle release cannot cover the dangerous case: it gives up the moment
# there is no stage, which is exactly the state that strands someone.
has "a session-scoped watchdog exists"        "_G.omashift_on_watchdog"
has "registered once per session, like the key listener" "_G.omashift_watchdog_bound"
has "it asks the compositor, not its own belief" "hl.get_current_submap() ~= SUBMAP"
has "it never consults stage to decide it is watching" "quiet_ticks = quiet_ticks + 1"
has "every screen write resets it"            "quiet_ticks = 0"
has "and it hands the keyboard back"          'reason = "watchdog"'

# Counted in TICKS, not off a wall clock: a clock that jumps across a suspend
# would fire it spuriously, and a clock read from /proc/uptime cannot be driven
# by the offline harness, which would leave the watchdog untestable.
assert_eq "the watchdog does not read a wall clock" 0 \
  "$(sed -n '/_G.omashift_on_watchdog = function/,/^end$/p' "$E" | grep -c 'now_ms')"

# ESCAPE CLOSES THE RESULTS PAGE. By then the submap is reset, so the game is not
# listening, and `omashift --stop` needs a terminal that was behind this surface
# the whole time. Waiting out a timer is not a dismissal.
# Escape lives in onPressed with every other key. Keys.onEscapePressed fires
# first and unconditionally, so a screen that wants Escape to mean something
# else -- the cabinet going back to the menu -- never got the chance.
assert_eq "escape is not handled ahead of everything else" 0 "$(code_count "$Q" 'Keys.onEscapePressed')"
has_in "escape is handled with the other keys"  "$Q" "case Qt.Key_Escape:"
assert_ge "and so does any other key"      1 "$(grep -c 'Keys.onPressed' "$Q")"
# But NOT a bare modifier. SUPER is the first half of a chord, not a decision to
# close anything, and dismissing on it meant the screen vanished before the
# second key landed: reaching for any normal shortcut killed the results page.
has_in "a bare modifier does not dismiss"  "$Q" "case Qt.Key_Super_L:"
has_in "and neither do the others"         "$Q" "case Qt.Key_Shift: case Qt.Key_Control: case Qt.Key_Alt:"
# Focus is taken ONLY on the screens meant to be dismissed. During play the
# submap owns every key, and a layer surface grabbing focus on top of that is two
# things fighting over the keyboard.
# FOCUS FOLLOWS VISIBILITY, not the screen name. Binding it to endScreen
# alone left an INVISIBLE surface holding every key after Escape dismissed it:
# the player pressed the key, watched the overlay vanish, and still had no
# keybindings until a timer tore the surface down. Trading a submap that would
# not let go for a hidden window that would not let go is not a fix.
# Asking for focus is not enough: an empty input region makes a layer surface
# un-focusable, so Exclusive focus was requested and silently declined and Escape
# never arrived. The mask has to lift exactly where focus is wanted.
has_in "the input mask lifts where focus is wanted" "$Q" \
  "mask: (surface.visible && surface.endScreen) ? null : passThrough"
assert_eq "the mask is never unconditional" 0 "$(grep -c '^    mask: Region {' "$Q")"

# The whole condition lives in one named property now, so both the layer's
# keyboard focus and the key-catcher's item focus read from the same place and
# cannot drift apart.
has_in "keyboard focus follows visibility" "$Q" "WlrLayershell.keyboardFocus: surface.wantsKeys"
has_in "and so does item focus"            "$Q" "focus: surface.wantsKeys"
# The dangerous shape, spelled out so it cannot come back: focus must never be
# decided by the screen alone.
assert_eq "focus is never bound to the screen alone" 0 \
  "$(grep -c 'keyboardFocus: surface.endScreen' "$Q")"
# The self-dismiss timers stay as the backstop, so focus is never the ONLY way
# out of the surface that just took the keyboard.
assert_ge "the dismiss timers survive as a backstop" 2 "$(grep -c 'dismissal.done = true' "$Q")"

# --stop must RETIRE the stage, not merely reset the submap. Resetting from
# outside left the stage alive in the engine with its timers running, so it kept
# publishing screens after the display was torn down, and threw away the
# partial run that retiring persists.
has_in "stop retires the stage"              "$L" "_G.omashift_on_retire()"
# The overlay is tracked by PID FILE. `pgrep -f quickshell...` matches any
# process whose command line mentions it, including the shell running this
# script. The display already learned that one the hard way.
has_in "the overlay is tracked by pid file"  "$L" 'QML_PID='
if grep -qE 'pgrep -f "quickshell|pkill -f "quickshell' "$L"; then
  _fail "the overlay is not tracked by pgrep" "a pid file" "a pgrep -f pattern is back"
else
  _pass "the overlay is not tracked by pgrep"
fi
# The LAUNCHER renders the ready screen. The terminal display used to, which
# meant the overlay had nothing to show and failed silently.
has_in "the launcher renders the ready screen" "$L" "_G.omashift_preview("

# THE OVERLAY MUST BE ABLE TO DISMISS ITSELF. It covers the screen and takes no
# input, so "omashift --stop closes this" pointed at a terminal the player could
# no longer see, which stranded a real player who had finished several stages.
# Terminal screens linger in the state file until the next launch, so without a
# timeout the overlay stays up forever.
if [[ -r $Q ]]; then
  grep -qF "property bool dismissed" "$Q" && _pass "the overlay can dismiss itself" \
    || _fail "the overlay can dismiss itself" "a dismissed flag" "absent"
  grep -qF "onTriggered: surface.dismissal.done = true" "$Q" && _pass "a timer clears a lingering screen" \
    || _fail "a timer clears a lingering screen" "a dismiss timer" "absent"
  # Dismissal must not be permanent, or the next stage renders to a hidden
  # surface and the game appears not to start at all.
  grep -qF "onViewChanged: dismissal.done = false" "$Q" && _pass "a new screen un-dismisses it" \
    || _fail "a new screen un-dismisses it" "dismissed reset on view change" "absent"
  # THE BACKSTOP. The rule above only covers screens known to be terminal, and a
  # completed stage was found stuck on a MID-PLAY screen that no timeout covered
  # It was fullscreen, with the submap already released so no key could clear it.
  # Any document that stops changing means the game is gone, whatever it shows.
  grep -qF "id: staleWatch" "$Q" && _pass "a frozen screen clears itself" \
    || _fail "a frozen screen clears itself" "a stale-state timer" "absent"
  grep -qF "staleWatch.restart()" "$Q" && _pass "any state write proves it is alive" \
    || _fail "any state write proves it is alive" "restart on doc change" "absent"
  # The old instruction pointed through the thing doing the blocking. Checked
  # against DISPLAYED text only. The comment explaining this bug quotes the old
  # string, and grepping the whole file flagged the explanation as the offence.
  if grep -E '^\s*text:' "$Q" | grep -qF "omashift --stop closes this"; then
    _fail "the overlay does not point at an unreachable terminal" "self-clearing" "the old text is back"
  else
    _pass "the overlay does not point at an unreachable terminal"
  fi
fi

# The key listener must be subscribed EXACTLY ONCE per Hyprland session. The
# engine reloads on every arm, and an unguarded hl.on added a subscriber each
# time that Hyprland could never drop, the same unbounded growth as the binding
# leak that once reached 5,687 entries. A long session accumulated dozens.
has "the key listener is bound once"               "if not _G.omashift_key_listener_bound then"
# It must dispatch through the global, or the surviving subscription would keep
# calling the FIRST engine ever loaded and a reload would change nothing.
has "the listener dispatches to the live engine"   "if _G.omashift_on_key then _G.omashift_on_key("
if grep -qE '^hl\.on\(' "$E"; then
  _fail "nothing subscribes at top level unguarded" "a guarded subscription" "a bare hl.on is back"
else
  _pass "nothing subscribes at top level unguarded"
fi

# The player, not the launcher, decides when the clock starts, and the gate
# must live OUTSIDE the submap. Arming inside it suppresses every keybinding, so
# a player who steps away before starting is stranded in game mode.
has "a start screen exists outside the submap"     "function _G.omashift_preview"
if grep -qF 'hl.bind("SPACE"' "$E"; then
  _fail "the gate is NOT inside the submap" "no bare SPACE bind in the submap" "found one"
else
  _pass "the gate is NOT inside the submap"
fi

# The dead-man's switch. Without it a crash strands the user with no bindings.
has "the panic exit is bound"                      "hl.bind(RETIRE_KEY, function() _G.omashift_on_retire() end)"
has "the panic exit resets the submap"             'hl.dispatch(hl.dsp.submap("reset"))'


# hl.define_submap ACCUMULATES bindings. Without teardown, 29 reloads produced
# 5,687 submap binds and 58 panic-exit handlers, each of which persisted the
# stage. One run wrote six identical history records.
# hl.unbind() reports success but does not remove submap-scoped bindings, so the
# submap must be defined exactly once and closures must dispatch through globals
# the reload replaces. Without this, reloads multiplied the binding table.
has "the submap is defined only once"              "if not _G.omashift_submap_defined then"
has "answers dispatch through a global"            "_G.omashift_on_answer"
has "retire dispatches through a global"           "_G.omashift_on_retire"
has "a stage is persisted at most once"            "if stage.persisted then return end"

# The HUD must repaint on modifier RELEASE as well as press, so its hook cannot
# filter to presses the way the timing path does. And modifiers must be read on
# the next loop turn: the key event fires before Hyprland updates its state.
has "modifier state comes from is_key_down"        "hl.is_key_down"
has "the HUD repaints on modifier change"          "repaint()"
has "modifiers are read after a deferral"          "timeout = 1, type = \"oneshot\""

# Telemetry follows the headline. Splits are where the diagnosis lives.
has "the results page is a single screen"          "local function show_results()"
has "the results page uses category splits"        "core.splits(stage)"

# THE HELPERS THIS FILE USES HAVE TO EXIST BY THE TIME THEY ARE USED. Reported
# last so it cannot bury a real failure list, and fatal, because an assertion
# that silently did not run is worse than one that failed: the suite reports
# green and nobody looks again.
if [[ -s ${MISSING_HELPER:-/nonexistent} ]]; then
  printf '\n\033[31mengine wiring: %d assertion(s) never ran\033[0m\n' \
    "$(wc -l < "$MISSING_HELPER")"
  sort -u "$MISSING_HELPER" | sed 's/^/  undefined: /'
  rm -f "$MISSING_HELPER"
  exit 1
fi
rm -f "$MISSING_HELPER"

suite_summary "engine wiring"

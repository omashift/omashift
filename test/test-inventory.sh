#!/bin/bash
# Tests for bin/omashift-inventory, the question-bank pipeline.
#
# Every assertion corresponds to a real property of the raw Omarchy data that
# would silently corrupt the game if it regressed. Two of these caught live bugs
# the day they were written; both are marked REGRESSION below.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
source ./helpers.sh

FIXTURE=fixtures/keybindings.txt
OUT=$(../bin/omashift-inventory "$FIXTURE")

echo "inventory:"

# --- shape -----------------------------------------------------------------
assert_eq "output is a JSON array" "array" "$(jq -r 'type' <<<"$OUT")"
assert_ge "yields a usable number of entries" 150 "$(jq 'length' <<<"$OUT")"

# --- every entry is playable ------------------------------------------------
assert_eq "every entry has a non-empty combo" 0 \
  "$(jq '[.[] | select((.combo // "") == "")] | length' <<<"$OUT")"
assert_eq "every entry has a non-empty description" 0 \
  "$(jq '[.[] | select((.description // "") == "")] | length' <<<"$OUT")"
assert_eq "every entry has at least one modifier" 0 \
  "$(jq '[.[] | select((.modifiers | length) == 0)] | length' <<<"$OUT")"
assert_eq "every entry has modmask > 0" 0 \
  "$(jq '[.[] | select(.modmask <= 0)] | length' <<<"$OUT")"

# REGRESSION: hyprctl -j binds reports an empty `key` and `keycode == 0` for 59
# described bindings, including every workspace switch. Using that source
# silently collapsed 59 bindings into 6 duplicates. A prompt whose key cannot be
# named is unanswerable, so an empty key must never reach the question bank.
assert_eq "REGRESSION: no entry has an empty key" 0 \
  "$(jq '[.[] | select((.key // "") == "")] | length' <<<"$OUT")"
assert_eq "REGRESSION: workspace 1 bindings survive with real keys" 3 \
  "$(jq '[.[] | select(.description | test("workspace 1$"))] | length' <<<"$OUT")"
assert_eq "REGRESSION: SUPER + 1 maps to switching to workspace 1" \
  "Switch to workspace 1" \
  "$(jq -r '.[] | select(.combo == "SUPER + 1") | .description' <<<"$OUT")"

# --- exclusions -------------------------------------------------------------
# REGRESSION: the hyprctl `.mouse` field reads false even for mouse bindings, so
# filtering on it silently let six mouse entries into the bank.
assert_eq "REGRESSION: mouse bindings are excluded" 0 \
  "$(jq '[.[] | select(.key | test("mouse|MOUSE"))] | length' <<<"$OUT")"
assert_eq "SUPER + K is excluded (it is the pit stop)" 0 \
  "$(jq '[.[] | select(.combo == "SUPER + K")] | length' <<<"$OUT")"
# Bare keys with no modifier carry no recall value and cannot be prompted.
assert_eq "bare unmodified keys are excluded" 0 \
  "$(jq '[.[] | select(.combo | test("^(PRINT|XF86)"))] | length' <<<"$OUT")"

# --- dedupe -----------------------------------------------------------------
# ALT+TAB legitimately carries two descriptions in the raw data. An ambiguous
# answer key makes a prompt unanswerable, so combos must be unique.
assert_eq "combos are unique" \
  "$(jq '[.[].combo] | length' <<<"$OUT")" \
  "$(jq '[.[].combo] | unique | length' <<<"$OUT")"
assert_eq "ALT + TAB appears exactly once" 1 \
  "$(jq '[.[] | select(.combo == "ALT + TAB")] | length' <<<"$OUT")"

# --- combo formatting -------------------------------------------------------
# Modifier order must be canonical and stable: SUPER, CTRL, ALT, SHIFT, key.
# Unstable ordering would break combo comparison and every stored score.
assert_eq "known binding renders canonically" "Close window" \
  "$(jq -r '.[] | select(.combo == "SUPER + W") | .description' <<<"$OUT")"
assert_eq "three-modifier order is SUPER, ALT, SHIFT" "SUPER + ALT + SHIFT + B" \
  "$(jq -r '[.[] | select(.modmask == 73) | .combo] | first' <<<"$OUT")"
assert_eq "no combo has a trailing or doubled separator" 0 \
  "$(jq '[.[] | select(.combo | test("\\+\\s*$|\\+\\s*\\+"))] | length' <<<"$OUT")"
assert_eq "modmask agrees with the modifier list" 0 \
  "$(jq '[.[] | select(
        .modmask != ( (if (.modifiers | index("SHIFT")) then 1  else 0 end)
                    + (if (.modifiers | index("CTRL"))  then 4  else 0 end)
                    + (if (.modifiers | index("ALT"))   then 8  else 0 end)
                    + (if (.modifiers | index("SUPER")) then 64 else 0 end) )
      )] | length' <<<"$OUT")"

# --- determinism ------------------------------------------------------------
SECOND=$(../bin/omashift-inventory "$FIXTURE")
assert_eq "output is deterministic across runs" "$(md5sum <<<"$OUT")" "$(md5sum <<<"$SECOND")"

suite_summary "inventory"

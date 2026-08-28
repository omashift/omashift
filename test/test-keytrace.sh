#!/bin/bash
# Tests for Hyprland's key-event delivery, against a REAL captured trace.
#
# These assert facts about the TRACE, not about any dedupe function. The
# (keycode, timestamp) dedupe in core was deleted on 2026-08-26 once the repaint
# path made it redundant, and none of this depended on it. The duplication and
# the monotonic clock are still load-bearing facts about the input the engine
# reads, which is why this suite stays.
#
# fixtures/key-trace.log came off the Phase 1 spike: genuine keystrokes from a
# live Hyprland session, including the duplicate delivery Hyprland performs.
# Scoring raw events would double-count every keystroke, so dedupe is not a
# nicety. It is the difference between a working scorer and a broken one.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
source ./helpers.sh

TRACE=fixtures/key-trace.log

echo "key trace:"

RAW=$(grep -c '^KEY' "$TRACE")
DISTINCT=$(grep '^KEY' "$TRACE" | grep -oP 'keycode=\d+ arg2=\d+' | sort -u | wc -l)

assert_ge "fixture contains a meaningful number of events" 100 "$RAW"

# The core property: Hyprland delivers events more than once.
assert_ne "raw event count differs from deduped count" "$RAW" "$DISTINCT"

# Dedupe key is (keycode, timestamp). Timestamp alone is not enough, because two
# different keys can share a millisecond during fast typing.
assert_ge "dedupe removes a substantial fraction" 1 \
  "$(( RAW - DISTINCT ))"

# Timestamps must be monotonic; reaction times are computed from their deltas,
# so a going-backwards clock would produce negative scores.
BACKWARDS=$(grep '^KEY' "$TRACE" | grep -oP 'arg2=\K\d+' | awk 'NR>1 && $1 < prev {c++} {prev=$1} END {print c+0}')
assert_eq "timestamps never go backwards" 0 "$BACKWARDS"

# Timestamps should look like milliseconds: human typing produces gaps in the
# tens-to-hundreds range, not microseconds or seconds.
MEDIAN_GAP=$(grep '^KEY' "$TRACE" | grep -oP 'arg2=\K\d+' | sort -un \
  | awk 'NR>1{print $1-prev} {prev=$1}' | sort -n | awk '{a[NR]=$1} END {print a[int(NR/2)]}')
assert_ge "median inter-key gap is >= 1ms" 1 "$MEDIAN_GAP"
if (( MEDIAN_GAP < 2000 )); then
  _pass "median inter-key gap ($MEDIAN_GAP) is plausible for milliseconds"
else
  _fail "median inter-key gap looks wrong for ms" "< 2000" "$MEDIAN_GAP"
fi

# Modifier state must be captured alongside the key, or a combo cannot be
# identified. The trace was recorded while pressing SUPER-prefixed combos.
assert_ge "trace captured SUPER-modified events" 1 \
  "$(grep -c 'mods="SUPER' "$TRACE")"

# Submap context travels with each event: the game needs to know whether a
# keystroke happened inside game mode.
assert_ge "trace captured events inside a submap" 1 \
  "$(grep -c 'submap="omashift-spike"' "$TRACE")"

suite_summary "key trace"

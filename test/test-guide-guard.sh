#!/bin/bash
# Tests for bin/omashift-guide-guard, the thing standing between a stage ending
# and a segfaulted compositor.
#
# Everything here runs against a STUBBED hyprctl, so no live Hyprland is needed
# and nothing can toggle the real overlay. The stub reads two env vars:
#
#   STUB_VERSION   what `hyprctl version` reports
#   STUB_REPORT    a printf template for the report `hyprctl eval` "writes",
#                  with @NONCE@ replaced by the nonce the guard actually sent
#
# The load-bearing test is the last one: it takes the Lua the guard generates and
# parses it with a real Lua. That chunk is only ever executed inside Hyprland, so
# without this it would be the one piece nothing covers, which is exactly how
# engine.lua broke silently four times in this project.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
source ./helpers.sh

GUARD=../bin/omashift-guide-guard
TMP=$(mktemp -d -t omashift-guard-test-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# The stub records the Lua path it was asked to dofile, so a later test can pull
# the generated chunk out and parse it.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hyprctl" <<'STUB'
#!/bin/bash
case "$1" in
  version) echo "Hyprland ${STUB_VERSION:-0.56.2} built from branch v x at commit y (z)."; exit 0 ;;
  eval)
    src=$(sed -n "s/^dofile('\(.*\)')$/\1/p" <<<"$2")
    [[ -n $src && -r $src ]] && cp "$src" "$STUB_CAPTURE" 2>/dev/null
    if [[ -n ${STUB_REPORT:-} ]]; then
      printf '%s' "${STUB_REPORT//@NONCE@/$(sed -n "s/.*NONCE    = \[==\[\(.*\)\]==\]/\1/p" "$src" 2>/dev/null)}" \
        > "$OMASHIFT_GUIDE_REPORT"
    fi
    echo ok; exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/hyprctl"

export STUB_CAPTURE="$TMP/generated.lua"
export OMASHIFT_GUIDE_REPORT="$TMP/report.txt"

# Run the guard against the stub. Sets $out (combined output) and $st (status).
guard() { # [args...]
  rm -f "$OMASHIFT_GUIDE_REPORT"
  out=$(STUB_VERSION="$VERSION" STUB_REPORT="$REPORT" \
        PATH="$TMP/bin:$PATH" bash "$GUARD" "$@" 2>&1)
  st=$?
}

CLEAN='nonce=@NONCE@
debug=yes
plugin=yes
verified=yes
pruned=0
keybinds=24
tables=2
remaining=0
'

echo "guide guard, version gate:"

VERSION=0.57.0 REPORT="$CLEAN"; guard
assert_eq "a Hyprland newer than 0.56.2 needs no guard"        0 "$st"
assert_contains "and says so"                                  "has the keybind fix" "$out"

# Regression guard on the boundary. The fix landed the same DAY 0.56.2 was
# tagged and missed it, so 0.56.2 itself is affected. An off-by-one here would
# silently disable the whole defense on the exact version that needs it.
VERSION=0.56.2 REPORT="$CLEAN"; guard
assert_eq "0.56.2 itself is treated as affected, and passes on a clean report" 0 "$st"
assert_eq "0.56.2 does not take the no-guard shortcut" "" "$(grep -o 'has the keybind fix' <<<"$out")"

echo
echo "guide guard, refusal cases:"

VERSION=0.56.2 REPORT=""; guard
assert_eq "no report written means refuse"                     1 "$st"
assert_contains "and say the guard could not run"              "could not run" "$out"

VERSION=0.56.2 REPORT='nonce=not-the-one
verified=yes
pruned=0
remaining=0
'; guard
assert_eq "a report from an older run is refused, not trusted" 1 "$st"
assert_contains "and is named as stale"                        "stale" "$out"

VERSION=0.56.2 REPORT='nonce=@NONCE@
debug=no
plugin=yes
verified=no
pruned=0
keybinds=0
tables=0
remaining=0
'; guard
assert_eq "unverifiable caches mean refuse even with remaining=0" 1 "$st"
assert_contains "and say why"                                  "cannot verify" "$out"

VERSION=0.56.2 REPORT='nonce=@NONCE@
debug=yes
plugin=yes
verified=yes
pruned=3
keybinds=24
tables=2
remaining=2
'; guard
assert_eq "expired entries that survived the prune mean refuse" 1 "$st"
assert_contains "and name the count"                           "2 expired keybind(s) still cached" "$out"

# A malformed count must fall to the UNSAFE side. Defaulting a missing number to
# zero is the classic way a safety check turns into a rubber stamp.
VERSION=0.56.2 REPORT='nonce=@NONCE@
verified=yes
pruned=0
remaining=lots
'; guard
assert_eq "a non-numeric remaining count is refused, not read as zero" 1 "$st"

echo
echo "guide guard, pass case:"

VERSION=0.56.2 REPORT="$CLEAN"; guard
assert_eq "clean caches on an affected Hyprland means proceed" 0 "$st"

VERSION=0.56.2 REPORT='nonce=@NONCE@
debug=yes
plugin=yes
verified=yes
pruned=4
keybinds=20
tables=2
remaining=0
'; guard
assert_eq "pruning dead entries still counts as safe"          0 "$st"
assert_contains "and reports what it removed"                  "pruned 4 dead keybind" "$out"

VERSION=0.56.2 REPORT='nonce=@NONCE@
verified=yes
pruned=4
remaining=2
'; guard --quiet
assert_eq "--quiet still refuses"                              1 "$st"
assert_eq "--quiet prints nothing"                             "" "$out"

echo
echo "guide guard, the generated Lua:"

VERSION=0.56.2 REPORT="$CLEAN"; guard
if [[ -r $STUB_CAPTURE ]]; then
  _pass "the guard hands hyprctl a Lua file to dofile"
else
  _fail "the guard hands hyprctl a Lua file to dofile" "a captured chunk" "nothing captured"
fi

# The path goes in through the environment, NOT as a trailing argument. With
# `lua -e CODE file`, `file` is the SCRIPT, so arg[1] is nil, loadfile(nil) reads
# STDIN, and this assertion quietly parses whatever stdin happens to be. It did
# exactly that when first written: it hung when stdin was a pipe and "passed"
# against empty input, which is worse than having no assertion at all.
parses() { # <path>  -- parse only, never execute
  CHUNK="$1" lua -e '
    local f, err = loadfile(os.getenv("CHUNK"))
    if not f then io.stderr:write(tostring(err), "\n"); os.exit(1) end
  ' </dev/null
}

if err=$(parses "$STUB_CAPTURE" 2>&1); then
  _pass "the generated chunk parses as Lua"
else
  _fail "the generated chunk parses as Lua" "loadfile succeeds" "$err"
fi

# Negative control, because the first version of the assertion above passed
# without ever reading the file. If a broken chunk does not fail, nothing here
# means anything.
printf 'local x = = 1\n' > "$TMP/broken.lua"
if parses "$TMP/broken.lua" 2>/dev/null; then
  _fail "a broken chunk is rejected" "non-zero exit" "accepted as valid Lua"
else
  _pass "a broken chunk is rejected"
fi

# And that it is reading the named file rather than anything on stdin.
if parses "$TMP/broken.lua" 2>/dev/null < "$STUB_CAPTURE"; then
  _fail "the parse reads the named file, not stdin" "non-zero exit" "read stdin instead"
else
  _pass "the parse reads the named file, not stdin"
fi

chunk=$(cat "$STUB_CAPTURE")
assert_contains "the report path reaches the chunk"     "$OMASHIFT_GUIDE_REPORT" "$chunk"
assert_contains "DO_PRUNE is true by default"           "local DO_PRUNE = true" "$chunk"

VERSION=0.56.2 REPORT="$CLEAN"; guard --check
assert_contains "--check generates a non-mutating chunk" "local DO_PRUNE = false" "$(cat "$STUB_CAPTURE")"

# THE safety property. tostring() is the only keybind operation that is
# null-safe on an expired keybind; every other one segfaults Hyprland. If a
# later edit reaches for set_enabled or a field read to decide liveness, this
# fails and says why.
#
# Comments are stripped first. The chunk's own header names the forbidden calls
# in order to warn about them, and an assertion that flags its own explanation
# is an assertion nobody trusts for long. This project has been here before.
code=$(sed 's/--.*//' "$STUB_CAPTURE")
for forbidden in set_enabled is_enabled ":remove(" ".enabled" ".description"; do
  if grep -qF "$forbidden" <<<"$code"; then
    _fail "the chunk never calls $forbidden on a keybind" "absent" "present, and this crashes Hyprland"
  else
    _pass "the chunk never calls $forbidden on a keybind"
  fi
done

# Negative control for the stripper: something that IS in the code must still be
# found after comments are removed. Otherwise a sed that blanked the whole file
# would make every assertion above pass silently.
assert_contains "comment stripping leaves the code intact" "is_expired" "$code"

echo
echo "guide guard, wiring:"

R=../bin/omashift-guide-restore
L=../bin/omashift

grep -qF 'GUARD="$HERE/omashift-guide-guard"' "$R" \
  && _pass "the restore looks for the guard beside itself" \
  || _fail "the restore looks for the guard beside itself" "GUARD=\$HERE/omashift-guide-guard" "absent"

grep -qF 'elif "$GUARD"; then' "$R" \
  && _pass "the restore only turns the overlay on if the guard passes" \
  || _fail "the restore only turns the overlay on if the guard passes" "the guard gates \$GUIDE on" "absent"

grep -qF 'if [[ ! -x $GUARD ]]; then' "$R" \
  && _pass "a missing guard is treated as unsafe, not skipped" \
  || _fail "a missing guard is treated as unsafe, not skipped" "an -x check that refuses" "absent"

grep -qF 'if "$HERE/bin/omashift-guide-guard"; then' "$L" \
  && _pass "the launcher gates turning the overlay OFF too" \
  || _fail "the launcher gates turning the overlay OFF too" "the guard gates \$GUIDE off" "absent"

grep -qF 'cp "$HERE/bin/omashift-guide-guard" "$BASE/omashift-guide-guard"' "$L" \
  && _pass "the guard is staged beside the restore for the engine" \
  || _fail "the guard is staged beside the restore for the engine" "a cp into \$BASE" "absent"

echo
echo "guide restore, end to end:"

# The restore is driven against a stub overlay toggle and a stub guard, so the
# branch that crashed a real compositor on 2026-08-25 is exercised on every run
# without going near the real plugin.
RTMP="$TMP/restore"
setup_restore() { # <guard exit status, or "none" to omit the guard entirely>
  rm -rf "$RTMP"; mkdir -p "$RTMP"
  cp ../bin/omashift-guide-restore "$RTMP/omashift-guide-restore"
  chmod +x "$RTMP/omashift-guide-restore"
  if [[ $1 != none ]]; then
    printf '#!/bin/bash\necho "guard ran" >> "$RTMP_LOG"\nexit %s\n' "$1" > "$RTMP/omashift-guide-guard"
    chmod +x "$RTMP/omashift-guide-guard"
  fi
  printf '#!/bin/bash\necho "toggle $*" >> "$RTMP_LOG"\n' > "$RTMP/toggle"
  chmod +x "$RTMP/toggle"
  : > "$RTMP/log"
}

run_restore() { # <guard status|none> <prior json>
  setup_restore "$1"
  mkdir -p "$RTMP/base"
  printf '%s' "$2" > "$RTMP/base/guide-prior.json"
  out=$(RTMP_LOG="$RTMP/log" OMASHIFT_BASE="$RTMP/base" OMASHIFT_GUIDE_TOGGLE="$RTMP/toggle" \
        bash "$RTMP/omashift-guide-restore" 2>&1)
  st=$?
  log=$(cat "$RTMP/log")
}

run_restore 0 '{"enabled":true}'
assert_contains "a passing guard lets the overlay be restored"  "toggle on" "$log"
assert_contains "and says it restored"                          "restored (was on)" "$out"
assert_eq "the prior-state file is consumed" "" "$(ls "$RTMP/base"/guide-prior.json 2>/dev/null)"

run_restore 1 '{"enabled":true}'
assert_eq "a refusing guard means the overlay is NEVER toggled" "" "$(grep -o 'toggle on' <<<"$log")"
assert_contains "the guard still ran"                           "guard ran" "$log"
assert_contains "and the refusal is reported"                   "left off" "$out"
assert_eq "the prior-state file is still consumed" "" "$(ls "$RTMP/base"/guide-prior.json 2>/dev/null)"

run_restore none '{"enabled":true}'
assert_eq "a missing guard means the overlay is NEVER toggled"  "" "$(grep -o 'toggle on' <<<"$log")"
assert_contains "and it says the guard is missing"              "guard missing" "$out"

run_restore 1 '{"enabled":false}'
assert_eq "an overlay that was already off is not toggled"      "" "$(grep -o 'toggle' <<<"$log")"
assert_eq "and the guard is not even consulted"                 "" "$(grep -o 'guard ran' <<<"$log")"
assert_contains "and it says so"                                "left off (was off)" "$out"

setup_restore 0
mkdir -p "$RTMP/base"
out=$(RTMP_LOG="$RTMP/log" OMASHIFT_BASE="$RTMP/base" OMASHIFT_GUIDE_TOGGLE="$RTMP/toggle" \
      bash "$RTMP/omashift-guide-restore" 2>&1); st=$?
assert_eq "with nothing recorded it is a silent no-op"          "" "$out"
assert_eq "and exits clean"                                     0 "$st"

suite_summary "guide guard"

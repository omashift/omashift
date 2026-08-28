#!/bin/bash
# `omashift --retired` and `--restore`, against a real history file.
#
# This rewrites the player's training record, which is the most valuable file
# the game owns, so it is worth exercising rather than reasoning about. Every
# case below is a way the rewrite could quietly destroy something.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
OM=../bin/omashift

run=0; failed=0
ok()  { run=$((run+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { run=$((run+1)); failed=$((failed+1)); printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$1" "$2"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

printf 'restore:\n'

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
HIST="$TMP/history.jsonl"

answers() { python3 -c "
import json,sys
n=0
for l in open(sys.argv[1]):
    if not l.strip(): continue
    try: rec=json.loads(l)
    except ValueError: continue
    n += len(rec.get('answers',[]))
print(n)" "$1"; }
skips() { python3 -c "
import json,sys
n=0
for l in open(sys.argv[1]):
    if not l.strip(): continue
    try: rec=json.loads(l)
    except ValueError: continue
    n += sum(1 for a in rec.get('answers',[]) if a.get('outcome')=='skipped')
print(n)" "$1"; }

cat > "$HIST" <<'JSONL'
{"stamp":"2026-08-27T09:00:00","course":"x","prompts":2,"correct":1,"offs":0,"points":0,"average_ms":0,"assisted":false,"completed":true,"clean":false,"answers":[{"combo":"A","description":"OCR","outcome":"skipped","reaction_ms":0},{"combo":"B","description":"Terminal","outcome":"correct","reaction_ms":900}]}
{"stamp":"2026-08-27T10:00:00","course":"x","prompts":2,"correct":0,"offs":1,"points":0,"average_ms":0,"assisted":false,"completed":true,"clean":false,"answers":[{"combo":"A","description":"OCR","outcome":"skipped","reaction_ms":0},{"combo":"C","description":"Browser","outcome":"off","reaction_ms":1200}]}
{"stamp":"2026-08-27T11:00:00","course":"x","prompts":1,"correct":0,"offs":0,"points":0,"average_ms":0,"assisted":false,"completed":true,"clean":false,"answers":[{"combo":"D","description":"Volume up","outcome":"skipped","reaction_ms":0}]}
JSONL

before_answers=$(answers "$HIST")
listing=$(OMASHIFT_HISTORY="$HIST" "$OM" --retired 2>&1)
grep -q "OCR" <<<"$listing" && ok "a twice-skipped action is listed" \
  || bad "a twice-skipped action is listed" "$listing"
grep -q "Volume up" <<<"$listing" \
  && bad "a once-skipped action is not listed" "$listing" \
  || ok "a once-skipped action is not listed"

# --- restoring one -----------------------------------------------------------
OMASHIFT_HISTORY="$HIST" "$OM" --restore "OCR" >/dev/null 2>&1
eq "both of its skips are gone, and only its" 1 "$(skips "$HIST")"
eq "and nothing else was touched" "$((before_answers - 2))" "$(answers "$HIST")"

python3 -c "
import json,sys
kept=[a['description'] for l in open(sys.argv[1]) if l.strip()
      for a in json.loads(l).get('answers',[])]
sys.exit(0 if 'Terminal' in kept and 'Browser' in kept else 1)" "$HIST" \
  && ok "answered records survive a restore" \
  || bad "answered records survive a restore" "an answer was deleted"

[[ -r "$HIST.bak" ]] && ok "the previous history is kept" || bad "the previous history is kept" "no .bak"

listing=$(OMASHIFT_HISTORY="$HIST" "$OM" --retired 2>&1)
grep -q "OCR" <<<"$listing" && bad "and it is back in rotation" "$listing" \
  || ok "and it is back in rotation"

# --- a line the rewriter cannot read is a line it must not delete ------------
printf 'this is not json at all\n' >> "$HIST"
OMASHIFT_HISTORY="$HIST" "$OM" --restore --all >/dev/null 2>&1
grep -qx 'this is not json at all' "$HIST" \
  && ok "an unreadable line is preserved untouched" \
  || bad "an unreadable line is preserved untouched" "it was dropped"
eq "and --all clears every skip" 0 "$(skips "$HIST")"

# --- refusing rather than guessing ------------------------------------------
OMASHIFT_HISTORY="$HIST" "$OM" --restore >/dev/null 2>&1
eq "restore with no argument refuses" 2 "$?"

printf '\n'
if (( failed )); then
  printf '\033[31mrestore: %d of %d FAILED\033[0m\n' "$failed" "$run"
  exit 1
fi
printf '\033[32mrestore: %d passed\033[0m\n' "$run"

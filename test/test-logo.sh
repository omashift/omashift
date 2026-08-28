#!/bin/bash
# The wordmark: does the committed SVG still match its generator, and does the
# lever still run a real H pattern?
#
# Two failure modes, both silent. An asset edited by hand drifts from the script
# that made it, and the next regeneration throws the edit away. And an animation
# can be well-formed SVG while being wrong: keyTimes out of order plays nothing,
# and a lever that moves diagonally has cut the corner instead of going through
# neutral, which is the one thing anyone who drives a manual would notice.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
ASSETS="$(pwd)/../assets"

run=0; failed=0
ok()  { run=$((run+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { run=$((run+1)); failed=$((failed+1)); printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$1" "$2"; }

printf 'logo:\n'

# The two PNGs are checked for EXISTENCE ONLY, unlike everything else here.
# They are rasterized from the SVG beside them with rsvg-convert, and a machine
# without it would fail a comparison it has no way to satisfy. The SVG is the
# source and it is compared; the bitmap is a convenience X and GitHub insist on.
for f in omashift-logo.svg omashift-logo-dark.svg omashift-mark.svg \
         omashift-icon.svg omashift-icon-transparent.svg omashift-icon-512.png \
         omashift-banner.svg omashift-banner-1500x500.png \
         four-mark.svg; do
  [[ -r "$ASSETS/$f" ]] && ok "$f exists" || bad "$f exists" "missing"
done

# THE GENERATOR IS THE SOURCE. Regenerated into a scratch copy, so a failing
# check never leaves the committed asset half-written.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The same shape as the real checkout, because the generator writes the QML one
# directory across from itself.
mkdir -p "$TMP/assets" "$TMP/qml"
cp "$ASSETS/make-logo.py" "$TMP/assets/"
if python3 "$TMP/assets/make-logo.py" >/dev/null 2>&1; then
  ok "the generator runs"
  for f in omashift-logo.svg omashift-logo-dark.svg omashift-mark.svg \
           omashift-icon.svg omashift-icon-transparent.svg omashift-banner.svg \
           four-mark.svg; do
    if cmp -s "$ASSETS/$f" "$TMP/assets/$f"; then
      ok "$f matches its generator"
    else
      bad "$f matches its generator" "regenerate with: python3 assets/make-logo.py"
    fi
  done
  # ONE MARK, TWO DRAWINGS. The launch page and the game's front screen have to
  # be the same logo, and a hand-kept QML copy drifts invisibly: nobody sees the
  # two side by side until someone puts a screenshot next to the README.
  if cmp -s "$ASSETS/../qml/Wordmark.qml" "$TMP/qml/Wordmark.qml"; then
    ok "qml/Wordmark.qml matches its generator"
  else
    bad "qml/Wordmark.qml matches its generator" "regenerate with: python3 assets/make-logo.py"
  fi
else
  bad "the generator runs" "python3 assets/make-logo.py failed"
fi

# NO MASK. It was one, and a mask is one more thing a renderer or a markdown
# sanitiser can decline to support, and one QML has no equivalent for without
# pulling in the effects module. The gate is plain rectangles now.
if grep -q "<mask" "$ASSETS/omashift-logo-dark.svg"; then
  bad "the mark needs nothing but rectangles" "found a <mask>"
else
  ok "the mark needs nothing but rectangles"
fi

# THE AVATAR. Square, and parked in fourth.
#
# X crops it to a circle and GitHub rounds the corners, so the gate has to sit
# inside the inscribed circle rather than fill the square. Checked as arithmetic
# rather than by eye, because "it looked fine in the preview" is how a mark ends
# up with its corners shaved off in one of the two places it is used.
ICON_REPORT=$(python3 - "$ASSETS/omashift-icon.svg" <<'ENDICON'
import re, sys, pathlib, math
svg = pathlib.Path(sys.argv[1]).read_text()
bad = []

m = re.search(r'viewBox="0 0 (\d+) (\d+)"', svg)
if not m or m.group(1) != m.group(2):
    bad.append("the icon is not square")
else:
    side = int(m.group(1))
    rects = [tuple(float(v) for v in r) for r in re.findall(
        r'<rect x="([-\d.]+)" y="([-\d.]+)" width="([\d.]+)" height="([\d.]+)"', svg)]
    # The full-bleed background is not part of the mark.
    art = [r for r in rects if not (r[2] >= side and r[3] >= side)]
    if not art:
        bad.append("the icon has no artwork in it")
    else:
        x0 = min(r[0] for r in art); x1 = max(r[0] + r[2] for r in art)
        y0 = min(r[1] for r in art); y1 = max(r[1] + r[3] for r in art)
        c = side / 2
        far = max(math.hypot(c - x, c - y) for x in (x0, x1) for y in (y0, y1))
        if far > c * 0.9:
            bad.append(f"the mark reaches {far:.0f} from center, past the safe circle")
        # Centerd, or a circular crop takes more off one side than the other.
        if abs((x0 + x1) / 2 - c) > 1 or abs((y0 + y1) / 2 - c) > 1:
            bad.append("the mark is not centerd in the square")

    circles = re.findall(r'<circle cx="([-\d.]+)" cy="([-\d.]+)"', svg)
    if len(circles) != 1:
        bad.append(f"expected one lever, found {len(circles)}")
    else:
        cx, cy = float(circles[0][0]), float(circles[0][1])
        # FOURTH: down and to the right. It is the top gear of a four speed and
        # the corner of the gate furthest from where a lever rests.
        if cx <= side / 2:
            bad.append("the lever is not on the right rail")
        if cy <= side / 2:
            bad.append("the lever is not at the bottom of the gate")
print("\n".join(bad))
ENDICON
)
if [[ -z $ICON_REPORT ]]; then
  ok "the avatar is square, centerd and parked in fourth"
else
  bad "the avatar is square, centerd and parked in fourth" "$ICON_REPORT"
fi

# THE ROUTE, analyzed once into a report. The first version of this ran the same
# analysis twice, once to print and once to count, and printed its bookkeeping.
REPORT=$(python3 "$ASSETS/check-route.py" "$ASSETS/omashift-logo-dark.svg")
if [[ -z $REPORT ]]; then
  ok "the lever runs a real H pattern"
else
  bad "the lever runs a real H pattern" "$REPORT"
fi

printf '\n'
if (( failed )); then
  printf '\033[31mlogo: %d of %d FAILED\033[0m\n' "$failed" "$run"
  exit 1
fi
printf '\033[32mlogo: %d passed\033[0m\n' "$run"

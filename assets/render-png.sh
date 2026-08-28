#!/bin/bash
# Rasterize the icon for the places that will not take an SVG.
#
#   ./assets/render-png.sh
#
# X and GitHub both want an uploaded bitmap for a profile or an org avatar, so
# the SVG cannot be the only artifact. Kept as a separate script rather than
# folded into make-logo.py, because that generator has no dependencies at all
# and this needs a renderer on the machine. A build step that only some machines
# can run should not be able to break the one that always works.
#
# 512 is enough for both: X asks for 400 square and resizes, GitHub takes any
# square and resizes. Anything larger is bytes in a git history for no gain.

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

command -v rsvg-convert >/dev/null 2>&1 || {
  echo "rsvg-convert not found (pacman -S librsvg)" >&2; exit 1; }

rsvg-convert -w 512 -h 512 "$HERE/omashift-icon.svg" -o "$HERE/omashift-icon-512.png" || exit 1
echo "wrote assets/omashift-icon-512.png"

# The X header, at the size X asks for. It arrived as a command typed by hand in
# the launch plan, which is the thing this script exists to stop: a build step
# that lives in prose is a build step nobody can rerun.
rsvg-convert -w 1500 -h 500 "$HERE/omashift-banner.svg" -o "$HERE/omashift-banner-1500x500.png" || exit 1
echo "wrote assets/omashift-banner-1500x500.png"

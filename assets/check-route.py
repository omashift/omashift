#!/usr/bin/env python3
"""Is the lever's route in an Omashift wordmark a real H pattern?

Prints one line per problem and nothing at all when it is fine, so a shell test
can treat empty output as a pass. Used by test/test-logo.sh.

An animation can be well-formed SVG and still be wrong in ways nobody notices
until it is on a launch page: keyTimes out of order plays nothing, and a lever
that moves diagonally has cut across the gate instead of going through neutral.
"""
import pathlib
import re
import sys

svg = pathlib.Path(sys.argv[1]).read_text()
bad = []

anims = re.findall(
    r'<animate attributeName="(c[xy])" values="([^"]+)" keyTimes="([^"]+)"', svg)
if len(anims) != 2:
    bad.append(f"expected two animate elements, found {len(anims)}")
else:
    for name, vals, times in anims:
        v = [float(x) for x in vals.split(";")]
        t = [float(x) for x in times.split(";")]
        if len(v) != len(t):
            bad.append(f"{name}: {len(v)} values against {len(t)} keyTimes")
        if not t or t[0] != 0.0 or abs(t[-1] - 1.0) > 1e-9:
            bad.append(f"{name}: keyTimes must run from 0 to 1")
        if any(b < a for a, b in zip(t, t[1:], strict=False)):
            bad.append(f"{name}: keyTimes go backwards")

    xs = [float(x) for x in anims[0][1].split(";")]
    ys = [float(x) for x in anims[1][1].split(";")]
    if [i for i in range(1, len(xs)) if xs[i] != xs[i - 1] and ys[i] != ys[i - 1]]:
        bad.append("the lever moves diagonally, so it skipped neutral")

    seen = set(zip(xs, ys, strict=True))
    # Two rails, three stops on each: up, neutral, down. Four gears and a
    # neutral on either rail is the whole gate. Anything else is not an H.
    if len(seen) != 6:
        bad.append(f"the gate has {len(seen)} positions, expected 6")
    rails = {x for x, _ in seen}
    if len(rails) != 2:
        bad.append(f"the gate has {len(rails)} rails, expected 2")

print("\n".join(bad))

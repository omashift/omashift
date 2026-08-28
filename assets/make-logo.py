#!/usr/bin/env python3
"""Generate the Omashift wordmark.

    python3 assets/make-logo.py

Writes omashift-logo.svg (dark ink, for light backgrounds) and
omashift-logo-dark.svg (light ink, for dark backgrounds), plus a static
omashift-mark.svg with the lever parked in neutral for places that will not
animate: favicons, AUR, an OG image.

WHY IT IS GENERATED RATHER THAN DRAWN

Every letter is a bitmap on one grid, so the whole wordmark shares a stroke
weight, a cap height and a chamfer by construction. Hand-drawn paths drift, and
the drift shows most in exactly this kind of face, where two strokes that differ
by three units read as a mistake rather than as a style.

THE STYLE IS OMARCHY'S, THE GLYPHS ARE NOT

Omarchy's own mark (/usr/share/omarchy/logo.svg) is a heavy chamfered block
face on a 15 unit grid, 240 tall. This matches the weight, the cap height, the
rectangular counters and the cut corners, and draws its own letters. Copying its
paths for the four letters the two words share and inventing the other four
would have produced a wordmark that is half one typeface and half another, which
is visible and is worse than not resembling it at all.

THE H IS THE SHIFT GATE

The idea is older than this file: the name works three ways at once (the
modifier key, a gear change, shifting to Omarchy) and the H is the only one of
them that can be made visible rather than explained. So the H is not a letter
here. It is drawn as the channel a gearbox lever moves through, and the lever
runs a real H pattern: up left for first, down through neutral for second,
across the neutral rail, up right for third, down for fourth. Anyone who has
driven a manual reads it without being told, and getting the motion wrong is
visible to exactly that audience, so the route below moves THROUGH neutral
between gates rather than teleporting across the crossbar.
"""

CELL = 24          # one grid square; letters are 10 cells tall
ROWS = 10
CAP = CELL * ROWS  # 240, the same cap height as Omarchy's mark
TOP = 15           # matches Omarchy's 15 unit margin above the caps
GAP = 24           # between letters
BLEED = 0.4        # overlap between neighboring cells, to hide the seams

# Ten rows, '#' is ink. Corner cells are cut on round letters, which is where
# the chamfered look comes from: it is in the bitmap, not a post-process.
GLYPHS = {
    "o": [".####.", "######", "##..##", "##..##", "##..##",
          "##..##", "##..##", "##..##", "######", ".####."],
    "m": [".######.", "########", "##.##.##", "##.##.##", "##.##.##",
          "##.##.##", "##.##.##", "##.##.##", "##.##.##", "##.##.##"],
    "a": [".####.", "######", "##..##", "##..##", "######",
          "######", "##..##", "##..##", "##..##", "##..##"],
    "s": [".####.", "######", "##....", "##....", "######",
          "######", "....##", "....##", "######", ".####."],
    "i": ["##", "##", "##", "##", "##", "##", "##", "##", "##", "##"],
    "f": [".####.", "######", "##....", "##....", "#####.",
          "#####.", "##....", "##....", "##....", "##...."],
    "t": [".####.", "######", "..##..", "..##..", "..##..",
          "..##..", "..##..", "..##..", "..##..", "..##.."],
    # A whole letter, and then a groove is cut out of it. Drawn at full weight
    # like every other letter, because the H has to still read as an H: a gate
    # that is only a gate leaves a hole in the middle of the word.
    "h": ["##..##", "##..##", "##..##", "##..##", "######",
          "######", "##..##", "##..##", "##..##", "##..##"],
}

WORD = "omashift"
GATE_AT = 4        # the h, counted from zero. Drawn, not set from the bitmap.
GATE_COLS = 6      # the width the gate occupies, in cells
SLOT = 1.0         # groove width, in cells. Narrower than the 2 cell strokes,
                   # so the H keeps its weight and the channel is cut INTO it.
                   # A whole cell, and the rails sit on cell boundaries, so the
                   # groove lands on half cells and the H minus the groove can
                   # be computed exactly as rectangles. It was a mask before,
                   # which is one more thing a renderer or a sanitiser can
                   # decline to support, and which QML has no equivalent of
                   # without pulling in the effects module.
KNOB = 0.70        # lever radius, in cells. Wider than half the groove, so it
                   # sits IN the gate rather than rattling around inside it.

# Merge runs of ink across a row into one rect. Fewer, longer rects means a
# smaller file and, more usefully, a shape that survives being scaled down to a
# favicon without the seams between neighboring squares showing.
def rects(bitmap, x0):
    out = []
    for r, row in enumerate(bitmap):
        c = 0
        while c < len(row):
            if row[c] == "#":
                start = c
                while c < len(row) and row[c] == "#":
                    c += 1
                out.append((x0 + start * CELL - BLEED, TOP + r * CELL - BLEED,
                            (c - start) * CELL + BLEED * 2, CELL + BLEED * 2))
            else:
                c += 1
    return out


def layout():
    """x offset and cell width of every letter, gate included."""
    places, x = [], TOP
    for i, ch in enumerate(WORD):
        cols = GATE_COLS if i == GATE_AT else len(GLYPHS[ch][0])
        places.append((ch, x, cols, i == GATE_AT))
        x += cols * CELL + GAP
    return places, x - GAP + TOP


# The H with its channel taken out, as rectangles.
#
# Everything is axis aligned and lands on half cells, so the difference is exact
# on a half cell grid: no mask, no clip path, no effects module. Rasterize, cut,
# then merge each row's runs back into as few rects as possible.
def gate_rects(x0, g):
    half = CELL / 2
    cols, rows = GATE_COLS * 2, ROWS * 2          # half cells
    on = [[False] * cols for _ in range(rows)]
    for r, row in enumerate(GLYPHS["h"]):
        for c, ch in enumerate(row):
            if ch == "#":
                on[r * 2][c * 2] = on[r * 2][c * 2 + 1] = True
                on[r * 2 + 1][c * 2] = on[r * 2 + 1][c * 2 + 1] = True

    def cut(x, y, w, h):
        """Clear a half-cell-aligned box, in user units relative to the glyph."""
        c0 = int(round((x - x0) / half))
        c1 = int(round((x - x0 + w) / half))
        r0 = int(round((y - TOP) / half))
        r1 = int(round((y - TOP + h) / half))
        for r in range(max(0, r0), min(rows, r1)):
            for c in range(max(0, c0), min(cols, c1)):
                on[r][c] = False

    slot = CELL * SLOT
    cut(g["left"] - slot / 2, g["top"], slot, g["bottom"] - g["top"])
    cut(g["right"] - slot / 2, g["top"], slot, g["bottom"] - g["top"])
    cut(g["left"], g["neutral"] - slot / 2, g["right"] - g["left"], slot)

    out = []
    for r in range(rows):
        c = 0
        while c < cols:
            if on[r][c]:
                start = c
                while c < cols and on[r][c]:
                    c += 1
                out.append((x0 + start * half - BLEED, TOP + r * half - BLEED,
                            (c - start) * half + BLEED * 2, half + BLEED * 2))
            else:
                c += 1
    return out


def gate(x0):
    """The H, as a channel with a lever in it.

    Returned as (walls, track, route) where the route is the lever's center
    line. The track is the slot itself, drawn darker than the letters so it
    reads as cut into the surface rather than sitting on it.
    """
    left = x0 + CELL          # center of the left rail
    right = x0 + CELL * 5
    top = TOP + CELL
    bottom = TOP + CELL * 9
    neutral = TOP + CELL * 5
    return dict(left=left, right=right, top=top, bottom=bottom, neutral=neutral)


# The six places the lever can actually be.
#
# INSET BY ITS OWN RADIUS at the ends of the channel, because a ball cannot
# reach the end of a slot: it stops when it touches. Without this the lever was
# centerd exactly on the end of the groove, so half of it was drawn over solid
# ink and every gear position showed a semicircle. Correct geometry and better
# drawing turn out to be the same fix, which is usually the sign it is the right
# one.
GEAR_GAP = 0.3      # cells of daylight left at the end of a gate

def gears(g):
    # Radius plus a little. The radius alone is the physical answer and it drew
    # badly: the ball ends up touching the cap of the slot, and since both are
    # the same color they fuse into one blob. The gap is a lie of about a third
    # of a cell, and it is what makes a ball read as a ball.
    inset = CELL * (KNOB + GEAR_GAP)
    return dict(L=g["left"], R=g["right"], N=g["neutral"],
                T=g["top"] + inset, B=g["bottom"] - inset)


# Where the lever sits, in order, and how long it rests there. A gearbox is not
# a metronome: the pauses in gear are what make it read as shifting rather than
# as a dot wandering a track.
def route(g):
    p = gears(g)
    L, R, T, B, N = p["L"], p["R"], p["T"], p["B"], p["N"]
    #    (x, y, seconds to hold once arrived)
    return [
        (L, N, 0.45),   # neutral, on the left rail
        (L, T, 0.55),   # first
        (L, N, 0.10),   # through neutral, not around it
        (L, B, 0.55),   # second
        (L, N, 0.20),
        (R, N, 0.20),   # across the neutral rail
        (R, T, 0.55),   # third
        (R, N, 0.10),
        (R, B, 0.55),   # fourth
        (R, N, 0.20),
        (L, N, 0.55),   # home
    ]


TRAVEL = 0.22   # seconds to move between two points


def animation(g, ink):
    stops = route(g)
    xs, ys, times, t = [], [], [], 0.0

    def at(x, y, when):
        """One stop on the lever's route: where it is, and when it is there."""
        xs.append(x)
        ys.append(y)
        times.append(when)

    total = 0.0
    for i, (_x, _y, hold) in enumerate(stops):
        if i:
            total += TRAVEL
        total += hold
    for i, (x, y, hold) in enumerate(stops):
        if i:
            t += TRAVEL
            at(x, y, t / total)
        else:
            at(x, y, 0.0)
        t += hold
        at(x, y, min(1.0, t / total))

    def fmt(values):
        return ";".join(f"{n:.4g}" for n in values)

    dur = f"{total:.2f}s"
    return f'''
    <circle cx="{stops[0][0]}" cy="{stops[0][1]}" r="{CELL * KNOB:g}" fill="{ink}">
      <animate attributeName="cx" values="{fmt(xs)}" keyTimes="{fmt(times)}"
               dur="{dur}" calcMode="linear" repeatCount="indefinite"/>
      <animate attributeName="cy" values="{fmt(ys)}" keyTimes="{fmt(times)}"
               dur="{dur}" calcMode="linear" repeatCount="indefinite"/>
    </circle>'''


def build(ink, track, animate=True):
    places, width = layout()
    height = TOP * 2 + CAP
    body = []
    for ch, x, _cols, is_gate in places:
        if is_gate:
            g = gate(x)
            for rx, ry, rw, rh in gate_rects(x, g):
                body.append(f'    <rect x="{rx:g}" y="{ry:g}" '
                            f'width="{rw:g}" height="{rh:g}"/>')
            if animate:
                body.append(animation(g, ink))
            else:
                body.append(
                    f'    <circle cx="{g["left"]}" cy="{g["neutral"]}" '
                    f'r="{CELL * KNOB:g}" fill="{ink}"/>')
        else:
            for rx, ry, rw, rh in rects(GLYPHS[ch], x):
                body.append(f'    <rect x="{rx:g}" y="{ry:g}" '
                            f'width="{rw:g}" height="{rh:g}"/>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
            f'width="{width}" height="{height}" role="img" aria-label="Omashift">\n'
            f'  <title>Omashift</title>\n'
            f'  <g fill="{ink}">\n' + "\n".join(body) + "\n  </g>\n</svg>\n")


# --- the patron's mark ------------------------------------------------------
#
# Four's mark: a teal disc carrying four white dots, three stacked at the right
# and one to the left of center. The four dots are the "four".
#
# GENERATED HERE FOR THE SAME REASON AS EVERYTHING ELSE IN THIS FILE, which is
# that a committed asset drifts from whatever made it unless something checks.
# It is drawn from the geometry in Four's own vector source rather than copied
# from it: disc r=65 at (157.2, 137.5), dots r=11.8 at (165.5, 105.4),
# (165.5, 137.5), (133.5, 137.5) and (165.5, 169.6). The same numbers drive
# qml/FourMark.qml, so the README and the game show one mark and not two.
#
# Approved for a public repository on 2026-08-27 by John as President and by the
# Chief Product Officer / Chief Technology Officer. That approval was asked for
# separately from the 2026-08-23 one, which covered the homage rather than the
# trademark.
FOUR_TEAL = "#1FCFCB"
FOUR_DISC = 65          # radius, in the source's units
FOUR_DOT = 11.8
# Offsets from the center of the disc, in the source's units.
FOUR_DOTS = ((8.3, -32.1), (8.3, 0), (-23.7, 0), (8.3, 32.1))


def four_mark():
    side = FOUR_DISC * 2
    c = FOUR_DISC
    dots = "\n".join(
        f'  <circle cx="{c + dx:g}" cy="{c + dy:g}" r="{FOUR_DOT:g}" fill="#FFFFFF"/>'
        for dx, dy in FOUR_DOTS)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {side} {side}" '
            f'width="{side}" height="{side}" role="img" aria-label="Four">\n'
            f'  <title>Four</title>\n'
            f'  <circle cx="{c}" cy="{c}" r="{FOUR_DISC}" fill="{FOUR_TEAL}"/>\n'
            f'{dots}\n</svg>\n')


# --- the avatar -------------------------------------------------------------
#
# Square, for X and for the GitHub org. Just the gate, with the lever parked in
# fourth: at the size an avatar is actually seen, eight letters are a smudge and
# one shape is a mark.
#
# FOURTH IS THE RIGHT GEAR TO PARK IN. It is the top of this gearbox, the game
# has four, and it is the corner of the gate furthest from where a lever rests.
# Down and to the right also reads as a position rather than as a decoration,
# which a lever sitting in neutral does not.
#
# X crops avatars to a circle and GitHub rounds the corners, so the gate is
# sized to sit well inside the inscribed circle rather than to fill the square.
# A mark that only survives one of the two crops is a mark with a bug in it.
ICON = 512          # canvas, square
ICON_CELL = 30      # the gate is 6 by 10 of these, so 180 by 300 inside 512
ICON_BG = "#1B1424"


def icon(ink, background=ICON_BG):
    cell, rows = ICON_CELL, ROWS
    w, h = GATE_COLS * cell, rows * cell
    x0 = (ICON - w) / 2
    y0 = (ICON - h) / 2

    # gate_rects() and gate() are written against the wordmark's grid constants,
    # so the shape is built there and moved here. Rebuilding it at a second
    # scale would be a second drawing of the same thing, which is the whole
    # reason this file exists.
    k = cell / CELL
    gx = TOP                      # any x; the shape is translated below
    g = gate(gx)
    boxes = gate_rects(gx, g)

    def place(v, origin, offset):
        return (v - origin) * k + offset

    body = []
    if background:
        body.append(f'  <rect width="{ICON}" height="{ICON}" fill="{background}"/>')
    body.append(f'  <g fill="{ink}">')
    for rx, ry, rw, rh in boxes:
        body.append(
            f'    <rect x="{place(rx, gx, x0):g}" y="{place(ry, TOP, y0):g}" '
            f'width="{rw * k:g}" height="{rh * k:g}"/>')

    # Fourth: the right rail, at the bottom of it. Taken from the route rather
    # than from a coordinate typed in here, so the gear the icon is parked in
    # cannot disagree with the gear the animation calls fourth.
    stops = route(g)
    fourth = stops[8]
    p = gears(g)
    assert (fourth[0], fourth[1]) == (p["R"], p["B"]), \
        "fourth is no longer down and right"
    body.append(
        f'    <circle cx="{place(fourth[0], gx, x0):g}" '
        f'cy="{place(fourth[1], TOP, y0):g}" r="{CELL * KNOB * k:g}"/>')
    body.append("  </g>")

    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {ICON} {ICON}" '
            f'width="{ICON}" height="{ICON}" role="img" '
            f'aria-label="Omashift">\n  <title>Omashift</title>\n'
            + "\n".join(body) + "\n</svg>\n")


# --- the banner -------------------------------------------------------------
#
# 1500x500, which is X's header size, with the lever parked in fourth like the
# avatar. A header cannot animate, so the one frame it gets should be the frame
# the mark is remembered in, and that is the same gear for the same reason: it
# is the top of this gearbox, and down-and-to-the-right reads as a position
# rather than as decoration.
#
# THE BACKGROUND IS THE PALETTE, NOT THE PICTURE. It is the quattro sky's own
# gradient and ground plane, in the colors qml/Theme.qml sampled, dimmed by the
# scrim the game dims every backdrop with. What it deliberately does NOT do is
# redraw the striped sun: that shape lives in qml/Sky.qml, and a second drawing
# of it here would be free to drift from the one players actually see, which is
# the whole reason the glyphs are generated rather than drawn.
#
# The scrim is doing the same job here as it does in the game. Gold on open
# magenta is a contrast fight, and the rule this project settled on is that the
# picture is atmosphere and the words are the mark. A little lighter than the
# game's 0.52 because nothing has to be READ over this one: it carries eight
# letters at 200px, not a pace note, so it can afford more of the color.
#
# Placement answers two crops. X hangs the avatar over the bottom left corner
# and trims the top and bottom on narrow screens, so the wordmark sits centerd
# and well inside the middle band, and the bottom left is left as empty ground
# for the avatar to sit on.
BANNER_W, BANNER_H = 1500, 500
BANNER_SCALE = 0.80        # the 1302-wide wordmark, at 1042
BANNER_CENTER = 0.43       # the wordmark's middle, as a share of the height
BANNER_GROUND = 0.85       # where the ground plane starts, as Sky.qml has it
BANNER_SCRIM = 0.45        # near the game's own 0.52, see below

# qml/Theme.qml, sampled from the quattro wallpaper. Named the same as there.
#
# NO AMBER BAND, and the game agrees without saying so. Theme.qml has a
# horizonBand between the coral and the ground, and Sky.qml then draws the
# ground over the bottom of its gradient, so that stop is never actually seen:
# the warmth down there comes from the sun instead. Kept here it was the only
# wrong note in the picture, because amber under a scrim is brown, and the band
# was wide enough to read as dirt rather than as light.
SKY_TOP, SKY_MID, SKY_LOW = "#762E78", "#D1396E", "#E7586E"
GROUND, HILLS = "#1C0C1E", "#A83583"
SCRIM_INK = "#1B1424"


def banner(ink="#F3F19A"):
    places, width = layout()
    height = TOP * 2 + CAP
    boxes, gate_geom = [], None
    for ch, x, _cols, is_gate in places:
        if is_gate:
            gate_geom = gate(x)
            boxes += gate_rects(x, gate_geom)
        else:
            boxes += rects(GLYPHS[ch], x)

    # Fourth, taken from the route rather than typed in, exactly as the avatar
    # takes it: the gear the banner is parked in cannot disagree with the gear
    # the animation calls fourth.
    stops = route(gate_geom)
    fourth = stops[8]
    p = gears(gate_geom)
    assert (fourth[0], fourth[1]) == (p["R"], p["B"]), \
        "fourth is no longer down and right"

    k = BANNER_SCALE
    x0 = (BANNER_W - width * k) / 2
    y0 = BANNER_H * BANNER_CENTER - height * k / 2
    ground_y = BANNER_H * BANNER_GROUND

    body = [
        '  <defs>',
        # ACROSS THE SKY, NOT THE CANVAS. Sky.qml runs its gradient over the
        # whole height and then draws the ground over the bottom of it, so the
        # amber stop lands behind the ground plane and is never seen. The game
        # gets its warmth from the sun instead, and this has no sun in it, so
        # the gradient is mapped to the sky itself and the horizon glows.
        f'    <linearGradient id="sky" gradientUnits="userSpaceOnUse" '
        f'x1="0" y1="0" x2="0" y2="{ground_y:g}">',
        f'      <stop offset="0" stop-color="{SKY_TOP}"/>',
        f'      <stop offset="0.45" stop-color="{SKY_MID}"/>',
        f'      <stop offset="1" stop-color="{SKY_LOW}"/>',
        '    </linearGradient>',
        '  </defs>',
        f'  <rect width="{BANNER_W}" height="{BANNER_H}" fill="url(#sky)"/>',
        f'  <rect y="{ground_y:g}" width="{BANNER_W}" '
        f'height="{BANNER_H - ground_y:g}" fill="{GROUND}"/>',
        f'  <rect y="{ground_y:g}" width="{BANNER_W}" height="3" fill="{HILLS}"/>',
        f'  <rect width="{BANNER_W}" height="{BANNER_H}" fill="{SCRIM_INK}" '
        f'opacity="{BANNER_SCRIM}"/>',
        f'  <g fill="{ink}" transform="translate({x0:g} {y0:g}) scale({k:g})">',
    ]
    for rx, ry, rw, rh in boxes:
        body.append(f'    <rect x="{rx:g}" y="{ry:g}" '
                    f'width="{rw:g}" height="{rh:g}"/>')
    body.append(f'    <circle cx="{fourth[0]:g}" cy="{fourth[1]:g}" '
                f'r="{CELL * KNOB:g}"/>')
    body.append("  </g>")

    return (f'<svg xmlns="http://www.w3.org/2000/svg" '
            f'viewBox="0 0 {BANNER_W} {BANNER_H}" '
            f'width="{BANNER_W}" height="{BANNER_H}" role="img" '
            f'aria-label="Omashift">\n  <title>Omashift</title>\n'
            + "\n".join(body) + "\n</svg>\n")


# --- the same wordmark, for the game ----------------------------------------
#
# Emitted from this file rather than hand-written in QML, for the reason the
# glyphs are generated in the first place: two drawings of the same mark drift,
# and the drift is invisible until they are side by side. The launch page and
# the front screen have to be the same logo.
#
# The rectangles are the SVG's, verbatim. The animation is the same route, said
# in QML: one sequence, one leg at a time, because the lever only ever moves
# along one axis and a pair of independent animations on x and y would be free
# to disagree about where it is.
def qml():
    places, width = layout()
    height = TOP * 2 + CAP
    boxes, gate_geom = [], None
    for ch, x, _cols, is_gate in places:
        if is_gate:
            gate_geom = gate(x)
            boxes += gate_rects(x, gate_geom)
        else:
            boxes += rects(GLYPHS[ch], x)

    model = ",\n            ".join(
        f"[{rx:g}, {ry:g}, {rw:g}, {rh:g}]" for rx, ry, rw, rh in boxes)

    stops = route(gate_geom)
    legs = []
    for i, (x, y, hold) in enumerate(stops):
        if i:
            legs.append(
                "            ParallelAnimation {\n"
                f"                NumberAnimation {{ target: knob; property: \"cx\"; "
                f"to: {x:g}; duration: {int(TRAVEL * 1000)}; "
                f"easing.type: Easing.InOutQuad }}\n"
                f"                NumberAnimation {{ target: knob; property: \"cy\"; "
                f"to: {y:g}; duration: {int(TRAVEL * 1000)}; "
                f"easing.type: Easing.InOutQuad }}\n"
                "            }")
        if hold:
            legs.append(
                f"            PauseAnimation {{ duration: {int(hold * 1000)} }}")

    r = CELL * KNOB
    return f'''// GENERATED by assets/make-logo.py. Do not edit; regenerate.
//
// The Omashift wordmark, and the H is not a letter. It is the channel a gearbox
// lever moves through, and the lever runs a real H pattern: up left for first,
// down through neutral for second, across the neutral rail, up right for third,
// down for fourth. It moves THROUGH neutral rather than across the crossbar,
// because getting that wrong is visible to exactly the people the pun is aimed
// at.
//
// This is attract mode. It belongs on the screen shown while the player's own
// keybindings are still live and the game is waiting, and it must never be
// something anyone has to sit through: nothing here delays a keypress.

import QtQuick

Item {{
    id: wordmark

    property color ink: "#F3F19A"
    /// Height of one grid cell. The whole mark is {ROWS} cells tall plus a
    /// {TOP} unit margin, so this is the only size anyone has to pick.
    property real cell: {CELL}

    readonly property real designWidth: {width}
    readonly property real designHeight: {height}
    readonly property real k: cell / {CELL}

    implicitWidth: designWidth * k
    implicitHeight: designHeight * k

    Item {{
        width: wordmark.designWidth
        height: wordmark.designHeight
        transform: Scale {{ xScale: wordmark.k; yScale: wordmark.k }}

        Repeater {{
            model: [
            {model}
            ]
            Rectangle {{
                required property var modelData
                x: modelData[0]; y: modelData[1]
                width: modelData[2]; height: modelData[3]
                color: wordmark.ink
            }}
        }}

        Rectangle {{
            id: knob
            property real cx: {stops[0][0]:g}
            property real cy: {stops[0][1]:g}
            width: {r * 2:g}; height: {r * 2:g}
            radius: {r:g}
            x: cx - {r:g}
            y: cy - {r:g}
            color: wordmark.ink

            SequentialAnimation {{
                running: wordmark.visible
                loops: Animation.Infinite
{chr(10).join(legs)}
            }}
        }}
    }}
}}
'''


if __name__ == "__main__":
    import pathlib
    here = pathlib.Path(__file__).parent
    # gold on dark, ink on light. The track is the letter color at low opacity
    # so it reads as the same material, cut away.
    (here / "omashift-logo-dark.svg").write_text(build("#F3F19A", "#F3F19A66"))
    (here / "omashift-logo.svg").write_text(build("#1B1424", "#1B142455"))
    (here / "omashift-mark.svg").write_text(
        build("#F3F19A", "#F3F19A66", animate=False))
    (here / "four-mark.svg").write_text(four_mark())
    (here / "omashift-icon.svg").write_text(icon("#F3F19A"))
    (here / "omashift-icon-transparent.svg").write_text(
        icon("#F3F19A", background=None))
    (here / "omashift-banner.svg").write_text(banner())
    (here / ".." / "qml" / "Wordmark.qml").write_text(qml())
    for f in ("omashift-logo.svg", "omashift-logo-dark.svg", "omashift-mark.svg",
              "omashift-icon.svg", "omashift-icon-transparent.svg",
              "omashift-banner.svg", "four-mark.svg", "../qml/Wordmark.qml"):
        print(f"{f}  {(here / f).stat().st_size} bytes")

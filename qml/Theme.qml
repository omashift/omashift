// The quattro palette.
//
// Sampled from the stock Omarchy wallpaper
// /usr/share/omarchy/themes/tokyo-night/backgrounds/1-quattro.jpg, a Group B
// rally coupe mid-jump against a synthwave sunset. Every Omarchy user already
// has that file, so the game's look references something they recognize rather
// than importing an outside aesthetic.
//
// These are the DEFAULT and the fallback. The eventual behavior is to keep the
// composition fixed and source the hues from the active theme's colors.toml, so
// a `hackerman` user is not forced into magenta. Shipping the sampled palette
// first means the composition can be judged before the theming is wired.

import QtQuick

QtObject {
    // Structure, in the order it stacks vertically.
    readonly property color skyTop:      "#762E78"   // zenith violet
    readonly property color skyMid:      "#D1396E"   // magenta core
    readonly property color skyLow:      "#E7586E"   // coral, the car's lit flank
    readonly property color horizonBand: "#EEA269"   // amber
    readonly property color ground:      "#1C0C1E"   // the image's commonest color
    readonly property color hills:       "#A83583"   // silhouetted ridge

    readonly property color surface:      "#351C49"
    readonly property color surfaceRaised: "#5F255E"

    // Meaning.
    readonly property color accent:  "#E7586E"   // correct, speed
    readonly property color hot:     "#D1396E"   // fastest, personal best
    readonly property color off:     "#972F47"   // penalty
    readonly property color apex:    "#EEA269"   // success
    readonly property color gold:    "#F3F19A"   // trophy, sun core
    readonly property color dust:    "#DBCD90"   // backlit dust, muted text
    readonly property color text:    "#F6DCAC"

    // One tier, one color, so a speed reads the same everywhere it appears.
    //
    // The ramp runs bright-warm to dark-cool, and that direction is the point:
    // faster must LOOK faster. The first pass ended on `dust`, a pale gold, so
    // `slow` came out brighter than every tier above it and the ladder read
    // backwards at a glance.
    function tierColor(tier) {
        switch (tier) {
        case "zero-latency": return gold;    // brightest
        case "on-rails":     return apex;
        case "clean":        return accent;
        case "steady":       return hot;
        default:             return hills;   // muted violet, the floor
        }
    }

    // Speed drives the same ramp, so the HUD and the result agree without
    // anything having to pass a tier around.
    function speedColor(kmh) {
        if (kmh >= 200) return gold;
        if (kmh >= 150) return apex;
        if (kmh >= 100) return accent;
        if (kmh >= 50)  return hot;
        return hills;
    }
}

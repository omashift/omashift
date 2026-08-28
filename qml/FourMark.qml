// The Four mark: a teal disc carrying four white dots.
//
// Drawn from the geometry in the vector source rather than shipped as a file.
// Every number below is lifted from `four-logo-long-black-text.svg`: the disc is
// r=65 at (157.2, 137.5), the dots are r=11.8 at (165.5, 105.4), (165.5, 137.5),
// (133.5, 137.5) and (165.5, 169.6). Three stacked at the right, one to the left
// of center. The four dots are the "four".
//
// WHY DRAWN AND NOT EMBEDDED. It keeps the mark exact at any size on any
// display, and it means the repo carries no copy of somebody's brand asset. The
// numbers are a faithful rendering, not an approximation.
//
// THE TEAL IS DECAL ONLY. #1FCFCB is very nearly the complement of this game's
// magenta, which is exactly what a sponsor decal wants and exactly what a UI
// accent must not be. One deliberate cold note against a warm scene reads as
// livery; ten reads as a clash. It appears here and nowhere else.

import QtQuick

Item {
    id: mark

    /// Diameter of the disc. Everything else is derived, so this is the only
    /// size anyone sets.
    property real size: 24

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size

    // The source's own units, so the ratios are checkable against the SVG.
    readonly property real k: size / 130      // 130 = the disc's diameter
    readonly property real dot: 11.8 * k

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: "#1FCFCB"
    }

    Repeater {
        // Offsets from the disc's center, in source units.
        model: [[8.3, -32.1], [8.3, 0], [-23.7, 0], [8.3, 32.1]]
        Rectangle {
            required property var modelData
            width: mark.dot
            height: mark.dot
            radius: width / 2
            color: "#FFFFFF"
            x: mark.width / 2 + modelData[0] * mark.k - width / 2
            y: mark.height / 2 + modelData[1] * mark.k - height / 2
        }
    }
}

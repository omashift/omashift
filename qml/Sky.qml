// The backdrop: gradient sky, hard-striped sun, flat silhouetted horizon.
//
// This is the structure the README asks to preserve independent of hue, so it is
// built from shapes and stops rather than from an image. Three reasons that
// matters: the wallpaper is a stock Omarchy asset and must not be redistributed;
// a drawn sky retints for any theme by moving colors rather than shipping a
// second file; and it scales to any resolution without a 5120x2880 decode.

import QtQuick

Item {
    id: sky
    property var theme

    // Sky. Violet at the zenith through magenta to coral at the horizon.
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.00; color: theme.skyTop }
            GradientStop { position: 0.45; color: theme.skyMid }
            GradientStop { position: 0.78; color: theme.skyLow }
            GradientStop { position: 0.92; color: theme.horizonBand }
        }
    }

    // The sun: a disc cut by hard horizontal stripes that widen toward the
    // bottom. Stripes are drawn as bands of the sky showing THROUGH the disc,
    // which is what makes the edges hard. A gradient would read as a glow.
    // Sized and placed off HEIGHT, never width: on a 3440-wide ultrawide a
    // width-relative sun becomes a wall that swallows the pace note, which is
    // exactly what the first pass did.
    //
    // It sits LOW, with roughly its lower third behind the horizon. That leaves
    // the middle band as clear sky for the text, and reads as a sun setting
    // rather than a disc pasted at eye level.
    Item {
        id: sun
        width: parent.height * 0.46
        height: width
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height * 0.52

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            gradient: Gradient {
                GradientStop { position: 0.0; color: theme.gold }
                GradientStop { position: 0.6; color: theme.apex }
                GradientStop { position: 1.0; color: theme.accent }
            }
        }

        // Hard cuts, thickening downward so the disc appears to sink into its
        // own light. Spaced across the visible upper portion, because the first pass
        // put them below the horizon line where all but one were hidden.
        //
        // A CUT IS THE DISC'S OWN SHAPE IN SKY COLOR, SHOWING THROUGH A BAND.
        // Two wrong versions came before it, and the difference between them is
        // where the round edge comes from:
        //
        //   1. A rectangle the full width of the sun's bounding box. The disc
        //      narrows toward the bottom while the cuts thicken, so the lowest
        //      visible ones hung out past the silhouette and the sun squared off
        //      exactly where it meets the horizon.
        //   2. A chord, sized from the circle at the band's far edge. Nothing
        //      hung out, but a chord is a straight line across a curve, so lit
        //      slivers of the disc were left standing either side of every cut
        //      and the bottom of the sun turned into a stack of steps.
        //
        // Neither can be right, because a rectangle has no curve in it and the
        // cut needs one at both ends. So the band CLIPS a sky-colored copy of
        // the disc instead: within the band nothing of the sun is left, and
        // outside the circle nothing is painted. The curve is the disc's own.
        Repeater {
            model: 7
            Item {
                readonly property real cutTop: sun.height * (0.30 + index * 0.072)
                readonly property real cutHeight: sun.height * (0.010 + index * 0.009)

                x: 0
                y: cutTop
                width: sun.width
                height: cutHeight
                clip: true

                // Sized and shaped like the sun, offset back up by the band's
                // own position so it lands exactly on top of it. Only the strip
                // the parent clips to survives.
                Rectangle {
                    width: sun.width
                    height: sun.height
                    radius: width / 2
                    y: -parent.cutTop
                    color: theme.skyLow
                }
            }
        }
    }

    // Backlit dust. The particle vocabulary, kept sparse: it should read as
    // atmosphere at a glance and never compete with a pace note.
    Repeater {
        model: 44
        Rectangle {
            width: Math.max(2, sky.height / 420)
            height: width
            radius: width / 2
            color: theme.dust
            // Deterministic scatter from the index, so the field does not
            // reshuffle on every repaint and pull the eye.
            opacity: 0.25 + ((index * 37) % 23) / 46
            x: sky.width * (((index * 61) % 100) / 100)
            y: sky.height * 0.18 + sky.height * 0.62 * (((index * 43) % 100) / 100)
        }
    }

    // Horizon: a flat silhouetted ridge, then ground.
    Item {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: parent.height * 0.15

        Rectangle {
            anchors.fill: parent
            color: theme.ground
        }
        // The ridge sits just above the ground plane and is a shade lighter,
        // which is what separates "hills" from "floor" without drawing terrain.
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 3
            color: theme.hills
        }
    }
}

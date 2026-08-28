// The quattro HUD: four modifiers, four wheels.
//
// quattro means all-wheel drive and there are exactly four modifiers, so the
// modifier indicator IS the drivetrain. This is the rare case where the theme
// and the interface want the same thing. It is on-theme decoration and also the
// single most useful live feedback the game can show, because a player's most
// common failure is holding the wrong modifier set. It reads instantly for a
// switcher who does not know the combos yet.
//
// Laid out as a car seen from above: SUPER and CTRL are the front axle, ALT and
// SHIFT the rear. The order matches core.WHEEL_ORDER so the two displays agree.

import QtQuick

Item {
    id: hud
    property var theme
    property var held: ({})
    property bool quattro: false

    /// Everything scales off this. A fixed pixel size is invisible on a 3440px
    /// display and enormous on a laptop panel; the HUD has to read at a glance
    /// on both, since reading it at a glance is its entire job.
    property real unit: 1.0

    readonly property real wheelW: 30 * unit
    readonly property real wheelH: 52 * unit
    readonly property real trackGap: 88 * unit

    /// The labels anchor OUTSIDE the wheels, so they do not fit inside the
    /// track width. Leaving them out of implicitWidth is what pushed CTRL and
    /// SHIFT off the right edge of the screen.
    readonly property real labelSpace: 78 * unit

    implicitWidth: trackGap + wheelW * 2 + labelSpace * 2
    implicitHeight: wheelH * 2 + 76 * unit

    // A wheel. Lit means its modifier is down.
    //
    // The lit state is deliberately loud. The first pass drew both states as
    // thin outlines and the difference was invisible across a desk, which
    // defeats the point, since reading modifier state AT A GLANCE is the whole
    // reason this exists.
    component Wheel: Item {
        property bool lit: false
        width: hud.wheelW
        height: hud.wheelH

        // Glow, so a lit wheel reads in peripheral vision rather than needing
        // to be looked at directly.
        Rectangle {
            anchors.centerIn: parent
            width: parent.width * 1.7
            height: parent.height * 1.5
            radius: width / 2
            visible: parent.lit
            color: Qt.rgba(hud.theme.accent.r, hud.theme.accent.g, hud.theme.accent.b, 0.22)
        }
        Rectangle {
            anchors.fill: parent
            radius: hud.wheelW * 0.28
            color: parent.lit ? hud.theme.accent
                              : Qt.rgba(hud.theme.ground.r, hud.theme.ground.g,
                                        hud.theme.ground.b, 0.55)
            border.width: Math.max(2, 2.5 * hud.unit)
            border.color: parent.lit ? hud.theme.gold
                                     : Qt.rgba(hud.theme.dust.r, hud.theme.dust.g,
                                               hud.theme.dust.b, 0.55)
            // Fast, because it tracks a key being held. A slow fade would lag
            // the hand and make the HUD look like it is guessing.
            Behavior on color { ColorAnimation { duration: 70 } }
            Behavior on border.color { ColorAnimation { duration: 70 } }

            // Tread. Three bars, so a lit wheel still reads as a WHEEL rather
            // than a colored slab.
            Column {
                anchors.centerIn: parent
                spacing: hud.wheelH * 0.12
                Repeater {
                    model: 3
                    Rectangle {
                        width: hud.wheelW * 0.52
                        height: Math.max(1, 1.5 * hud.unit)
                        color: parent.parent.parent.lit
                               ? Qt.rgba(hud.theme.ground.r, hud.theme.ground.g,
                                         hud.theme.ground.b, 0.55)
                               : Qt.rgba(hud.theme.dust.r, hud.theme.dust.g,
                                         hud.theme.dust.b, 0.35)
                    }
                }
            }
        }
    }

    Item {
        id: car
        anchors.centerIn: parent
        width: hud.trackGap + hud.wheelW * 2
        height: hud.wheelH * 2 + 52 * hud.unit

        // The body, drawn as a body rather than a bar. It sits BEHIND the
        // wheels and inset from them, which is what makes the layout read as a
        // car from above instead of four rectangles around a line.
        Rectangle {
            anchors.centerIn: parent
            width: hud.trackGap * 0.78
            height: parent.height * 0.92
            radius: hud.wheelW * 0.45
            color: Qt.rgba(hud.theme.ground.r, hud.theme.ground.g, hud.theme.ground.b, 0.35)
            border.width: Math.max(2, 2 * hud.unit)
            border.color: Qt.rgba(hud.theme.dust.r, hud.theme.dust.g, hud.theme.dust.b,
                                  hud.quattro ? 0.9 : 0.35)
            Behavior on border.color { ColorAnimation { duration: 120 } }

            // The door plate is 4, because quattro means four, and a period rally
            // plate carries no trademark where a badge would.
            Text {
                anchors.centerIn: parent
                text: "4"
                color: Qt.rgba(hud.theme.dust.r, hud.theme.dust.g, hud.theme.dust.b,
                               hud.quattro ? 0.95 : 0.4)
                font.pixelSize: 22 * hud.unit
                font.bold: true
            }
        }

        Wheel { lit: !!hud.held.SUPER; x: 0;                            y: 0 }
        Wheel { lit: !!hud.held.CTRL;  x: hud.trackGap + hud.wheelW;    y: 0 }
        Wheel { lit: !!hud.held.ALT;   x: 0;                            y: parent.height - hud.wheelH }
        Wheel { lit: !!hud.held.SHIFT; x: hud.trackGap + hud.wheelW;    y: parent.height - hud.wheelH }

        // Labels sit outside the wheels so they never overlap a lit face, and
        // brighten with their own wheel so the pairing is unambiguous.
        component WheelLabel: Text {
            property bool lit: false
            color: lit ? hud.theme.gold
                       : Qt.rgba(hud.theme.dust.r, hud.theme.dust.g, hud.theme.dust.b, 0.7)
            font.pixelSize: 14 * hud.unit
            font.letterSpacing: 1
            font.bold: lit
        }

        WheelLabel {
            text: "SUPER"; lit: !!hud.held.SUPER
            anchors { right: parent.left; rightMargin: 10 * hud.unit; top: parent.top; topMargin: 16 * hud.unit }
        }
        WheelLabel {
            text: "CTRL"; lit: !!hud.held.CTRL
            anchors { left: parent.right; leftMargin: 10 * hud.unit; top: parent.top; topMargin: 16 * hud.unit }
        }
        WheelLabel {
            text: "ALT"; lit: !!hud.held.ALT
            anchors { right: parent.left; rightMargin: 10 * hud.unit; bottom: parent.bottom; bottomMargin: 16 * hud.unit }
        }
        WheelLabel {
            text: "SHIFT"; lit: !!hud.held.SHIFT
            anchors { left: parent.right; leftMargin: 10 * hud.unit; bottom: parent.bottom; bottomMargin: 16 * hud.unit }
        }
    }

    // All four down is full quattro, and it is worth calling out. It is the
    // moment the drivetrain metaphor and the keyboard actually coincide.
    Text {
        text: "FULL QUATTRO"
        visible: hud.quattro
        color: hud.theme.gold
        font.pixelSize: 14 * hud.unit
        font.bold: true
        font.letterSpacing: 3
        anchors { horizontalCenter: parent.horizontalCenter; top: car.bottom; topMargin: 8 * hud.unit }
    }
}

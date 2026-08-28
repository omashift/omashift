// The trophy case, visually.
//
// The design called for this and said why: it is the screen people screenshot,
// and text undersells it. The terminal cabinet has always shown the same data,
// deliberately, so the Cabinet was usable before this existed rather than
// waiting on it.
//
// Both read the SAME model from lib/cabinet.lua. Nothing here decides what
// counts as won, which is why a badge cannot disagree with the terminal listing.
//
// LOCKED AND UNEARNED TROPHIES ARE SHOWN. A mostly empty cabinet is the roadmap,
// and that matters most to a new player. Dimming them rather than hiding them is
// the whole point of the screen.
//
// Attribution stays off the badge face. `omashift-cabinet --why` explains where
// the names come from; a permanent display that printed its references would
// read as a patron endorsement.

import QtQuick

Item {
    id: root

    required property var doc
    required property var theme
    required property real u

    readonly property var sections: doc.sections || []
    readonly property var summary: doc.summary || ({})

    // Won trophies carry the tier's own color; a held tier should look like
    // what it is. Everything unearned goes muted, so the eye lands on the
    // filled shelves first.
    function badgeColor(row) {
        if (!row.won) return theme.hills;
        if (row.tiered && row.tiered.tier === "gold") return theme.gold;
        if (row.tiered && row.tiered.tier === "silver") return theme.dust;
        if (row.tiered) return theme.apex;
        if (row.complete) return theme.gold;
        return theme.accent;
    }

    function markText(row) {
        if (row.tiered) return row.tiered.tier ? row.tiered.tier.toUpperCase() : "-";
        if (row.per_course) return row.held + " / " + row.of;
        return row.won ? "WON" : "-";
    }

    function detailText(row) {
        if (row.tiered) {
            const t = row.tiered;
            return t.maxed ? (t.count + "  ·  maxed")
                           : (t.count + " / " + t.next_at + " to " + t.next_tier);
        }
        if (row.per_course) return row.complete ? "every course" : "one per course";
        return row.day ? ("earned " + row.day) : (row.locked || "not yet");
    }

    // A scrim, for the same reason the pace note has one: the sky is at its
    // brightest exactly where the shelves sit. Without it the sun rises straight
    // through the lower half and "Fast Off The Blocks", "Presence" and "Rework"
    // are unreadable, which is a poor showing for the screen people screenshot.
    //
    // Not opaque. The sky is the game's identity and a trophy case floating in
    // nothing would look like a settings dialog; this dims it enough to read
    // over and leaves it visible.
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0.11, 0.05, 0.12, 0.80)
    }

    Column {
        anchors.centerIn: parent
        width: Math.min(parent.width * 0.9, 150 * u)
        spacing: 1.6 * u

        Text {
            text: "THE CABINET"
            color: root.theme.gold
            font.pixelSize: 3.4 * u
            font.bold: true
            font.letterSpacing: 6
            anchors.horizontalCenter: parent.horizontalCenter
        }

        Text {
            text: (root.summary.won || 0) + " of " + (root.summary.total || 0) + " earned"
            color: root.theme.dust
            font.pixelSize: 1.8 * u
            font.letterSpacing: 2
            anchors.horizontalCenter: parent.horizontalCenter
        }

        // Four shelves side by side. Vertical stacking ran off the bottom of a
        // laptop panel at 31 trophies, and a cabinet you have to scroll is not a
        // cabinet, it is a list.
        Row {
            spacing: 2.5 * u
            anchors.horizontalCenter: parent.horizontalCenter

            Repeater {
                model: root.sections

                Column {
                    required property var modelData
                    spacing: 0.7 * u
                    width: (150 * root.u - 7.5 * root.u) / 4

                    Text {
                        // Just the class, not the explanation the terminal
                        // carries: "MILESTONES: once, ever" is a legend for a
                        // listing. Here the badges say it themselves.
                        text: modelData.label.split(": ")[0]
                        color: root.theme.text
                        font.pixelSize: 1.5 * u
                        font.letterSpacing: 3
                        opacity: 0.8
                    }

                    Repeater {
                        model: modelData.rows

                        Rectangle {
                            required property var modelData
                            width: parent.width
                            height: 6.6 * root.u
                            radius: 0.5 * root.u
                            color: modelData.won ? Qt.rgba(1, 1, 1, 0.07)
                                                 : Qt.rgba(0, 0, 0, 0.18)
                            border.width: 1
                            border.color: modelData.won
                                ? Qt.alpha(root.badgeColor(modelData), 0.55)
                                : Qt.rgba(1, 1, 1, 0.06)
                            opacity: modelData.won ? 1.0 : 0.55

                            Row {
                                anchors.fill: parent
                                anchors.margins: 0.8 * root.u
                                spacing: 0.8 * root.u

                                // The tier chip. Fixed width so the phrases line
                                // up down the shelf regardless of what is held.
                                Rectangle {
                                    width: 7.5 * root.u
                                    height: parent.height
                                    radius: 0.3 * root.u
                                    color: modelData.won
                                        ? Qt.alpha(root.badgeColor(modelData), 0.22)
                                        : "transparent"
                                    Text {
                                        anchors.centerIn: parent
                                        text: root.markText(modelData)
                                        color: root.badgeColor(modelData)
                                        font.pixelSize: 1.1 * root.u
                                        font.bold: modelData.won
                                        font.letterSpacing: 1
                                    }
                                }

                                Column {
                                    width: parent.width - 8.3 * root.u
                                    spacing: 0.2 * root.u

                                    Text {
                                        width: parent.width
                                        text: modelData.phrase
                                        color: modelData.won ? root.theme.text : root.theme.dust
                                        font.pixelSize: 1.4 * root.u
                                        font.bold: modelData.won
                                        elide: Text.ElideRight
                                    }

                                    // WHAT IT MEANS TO HAVE WON IT. A case full
                                    // of phrases nobody can decode is a wall of
                                    // nicknames: "Cache Hit" and "Sharp Knives"
                                    // say nothing about what you did.
                                    //
                                    // Not the attribution. That is `source`, and
                                    // it stays behind `--why`, because a
                                    // permanent display naming its references
                                    // reads as a patron endorsement.
                                    Text {
                                        width: parent.width
                                        visible: (modelData.note || "") !== ""
                                        text: modelData.note || ""
                                        color: root.theme.dust
                                        font.pixelSize: 1.0 * root.u
                                        opacity: modelData.won ? 0.85 : 0.6
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        width: parent.width
                                        text: root.detailText(modelData)
                                        color: root.theme.dust
                                        font.pixelSize: 1.1 * root.u
                                        opacity: 0.75
                                        elide: Text.ElideRight
                                    }

                                    // Progress toward the next tier, drawn only
                                    // where there IS a next tier. A maxed
                                    // trophy has no bar because it has nothing
                                    // left to fill.
                                    Rectangle {
                                        visible: modelData.tiered !== undefined
                                                 && modelData.tiered.progress !== undefined
                                                 && modelData.tiered.progress !== null
                                        width: parent.width
                                        height: 0.35 * root.u
                                        radius: height / 2
                                        color: Qt.rgba(1, 1, 1, 0.10)
                                        Rectangle {
                                            width: parent.width * Math.max(0, Math.min(1,
                                                modelData.tiered ? (modelData.tiered.progress || 0) : 0))
                                            height: parent.height
                                            radius: parent.radius
                                            color: root.badgeColor(modelData)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // HOW TO LEAVE. This surface holds exclusive keyboard focus, so while it
        // is up the whole keymap is dead and Escape is the only key that works.
        // A screen that takes your keyboard and does not say how to give it back
        // is the same mistake the in-play HUD made before it started printing
        // the retire chord.
        Text {
            text: "P saves a picture  ·  ESC to close"
            color: root.theme.dust
            font.pixelSize: 1.3 * u
            font.letterSpacing: 2
            opacity: 0.8
            anchors.horizontalCenter: parent.horizontalCenter
        }

        Text {
            visible: (root.summary.days || 0) > 0
            text: "played on " + root.summary.days + " day"
                  + (root.summary.days === 1 ? "" : "s")
                  + "  ·  most recently " + (root.summary.last_day || "")
            color: root.theme.dust
            font.pixelSize: 1.2 * u
            opacity: 0.7
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }
}

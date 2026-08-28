// The Logbook, visually.
//
// ONE QUESTION: am I getting better? The verdict is the biggest thing on the
// screen because it is the thing being asked; everything else is the working
// that backs it up, and a player who only reads the top line has still got the
// answer.
//
// Same contract as the Cabinet. Both read a model built in lib/stats.lua, so a
// number here cannot disagree with `omashift-stats`, and nothing in this file
// decides what counts as improvement.
//
// The terminal report is not replaced by this and is not a lesser version of
// it: `omashift-stats` still owns blind spots, every ghost time and the full
// reaction ladder. This screen answers one question well.

import QtQuick

Item {
    id: root

    required property var doc
    required property var theme
    required property real u

    readonly property var trend: doc.trend || ({})
    readonly property var lifetime: doc.lifetime || ({})
    readonly property var last: doc.last || ({})
    readonly property var series: doc.series || []

    readonly property string verdictWord:
          !trend.enough           ? "TOO SOON TO SAY"
        : trend.verdict === "faster" ? "YES"
        : trend.verdict === "slower" ? "NOT LATELY"
        : trend.verdict === "steady" ? "HOLDING STEADY"
        : "TOO SOON TO SAY"

    readonly property color verdictColor:
          !trend.enough                ? theme.dust
        : trend.verdict === "faster"   ? theme.gold
        : trend.verdict === "slower"   ? theme.accent
        : theme.text

    function kmh(v) { return (v === undefined || v === null) ? "-" : v + " km/h" }

    // The ends of the pace axis, so the chart carries its own scale. A line
    // with no numbers on it is a shape, not a measurement.
    //
    // Decided in lib/stats.lua, not here. The terminal sparkline draws against
    // the same two numbers, so the two Logbooks are the same drawing, and the
    // labels below describe the line that was actually drawn rather than the
    // extremes of the data behind it.
    readonly property var chart: doc.chart || ({})
    function pct(v) { return (v === undefined || v === null) ? "-" : v + "%" }

    // The scrim, for the same reason every other full screen has one: these are
    // small numbers over a photograph, and the photograph wins without it.
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0.05, 0.06, 0.12, 0.86)
    }

    Column {
        anchors.centerIn: parent
        width: Math.min(parent.width * 0.9, 150 * root.u)
        spacing: 1.4 * root.u

        Text {
            text: "THE LOGBOOK"
            color: root.theme.gold
            font.pixelSize: 3.0 * root.u
            font.bold: true
            font.letterSpacing: 6
            anchors.horizontalCenter: parent.horizontalCenter
        }

        // --- the answer -----------------------------------------------------
        Column {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 0.3 * root.u
            visible: root.doc.empty !== true

            Text {
                text: "ARE YOU GETTING BETTER?"
                color: root.theme.dust
                font.pixelSize: 1.5 * root.u
                font.letterSpacing: 4
                opacity: 0.85
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Text {
                text: root.verdictWord
                color: root.verdictColor
                font.pixelSize: 5.5 * root.u
                font.bold: true
                font.letterSpacing: 3
                anchors.horizontalCenter: parent.horizontalCenter
            }

            // The paired number, which is the one that survives moving to a
            // harder course: same bindings, compared with themselves.
            Text {
                visible: root.trend.enough === true
                         && !!root.trend.paired
                         && root.trend.paired.enough === true
                text: {
                    const p = root.trend.paired || ({});
                    return p.improved + " of " + p.compared + " bindings improved"
                         + ": " + p.before_kmh + " km/h to " + p.after_kmh + " km/h";
                }
                color: root.theme.text
                font.pixelSize: 1.6 * root.u
                opacity: 0.9
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Text {
                visible: root.trend.enough !== true
                text: (root.trend.stages || 0) + " of " + (root.trend.needed || 0)
                      + " stages recorded. Play "
                      + Math.max(0, (root.trend.needed || 0) - (root.trend.stages || 0))
                      + " more and this fills in."
                color: root.theme.dust
                font.pixelSize: 1.5 * root.u
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }

        Text {
            visible: root.doc.empty === true
            text: "Nothing recorded yet. Play a stage and this fills in."
            color: root.theme.dust
            font.pixelSize: 2 * root.u
            anchors.horizontalCenter: parent.horizontalCenter
        }

        // --- the graph ------------------------------------------------------
        //
        // Every stage in the order it was played. Two lines because there are
        // two ways to get better and they do not move together: pace and
        // accuracy. QUICKER IS HIGHER, which is the opposite of the underlying
        // milliseconds, because a chart that climbs as you get worse has to be
        // explained every time anyone looks at it.
        Item {
            visible: root.series.length > 1
            width: parent.width
            height: 22 * root.u

            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(1, 1, 1, 0.04)
                radius: 0.6 * root.u
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.08)
            }

            Canvas {
                id: chart
                anchors.fill: parent
                anchors.margins: 2 * root.u

                // Repaint whenever the numbers change. A Canvas painted once at
                // load shows the first document forever, which on a screen the
                // menu can reopen is a stale screen that looks like a live one.
                Connections {
                    target: root
                    function onSeriesChanged() { chart.requestPaint() }
                }

                onPaint: {
                    const ctx = getContext("2d");
                    ctx.reset();
                    const pts = root.series;
                    if (!pts || pts.length < 2) return;

                    const W = width, H = height;

                    function line(values, axisLo, axisHi, color, dot) {
                        let lo = axisLo, hi = axisHi;
                        if (lo === null || lo === undefined
                            || hi === null || hi === undefined) {
                            lo = null; hi = null;
                            for (const v of values) {
                                if (v === undefined || v === null) continue;
                                if (lo === null || v < lo) lo = v;
                                if (hi === null || v > hi) hi = v;
                            }
                        }
                        if (lo === null) return;
                        // A flat series is drawn flat, down the middle. Scaling
                        // it to full height would draw a mountain range out of
                        // forty identical numbers.
                        const span = (hi === lo) ? 0 : (hi - lo);
                        ctx.beginPath();
                        ctx.lineWidth = Math.max(2, 0.28 * root.u);
                        ctx.strokeStyle = color;
                        ctx.lineJoin = "round";
                        let started = false;
                        const xy = [];
                        for (let i = 0; i < values.length; i++) {
                            const v = values[i];
                            if (v === undefined || v === null) continue;
                            // Clamped: a fixed axis can be narrower than the
                            // data, and a record stage belongs at the top of
                            // the chart rather than off it.
                            let t = span === 0 ? 0.5
                                  : Math.max(0, Math.min(1, (v - lo) / span));
                            const x = W * (values.length === 1 ? 0.5 : i / (values.length - 1));
                            const y = H - (0.1 * H + t * 0.8 * H);
                            xy.push([x, y]);
                            if (!started) { ctx.moveTo(x, y); started = true; }
                            else ctx.lineTo(x, y);
                        }
                        ctx.stroke();
                        if (!dot || xy.length === 0) return;
                        // The most recent stage, marked. "Where am I now" is the
                        // point on this chart anyone actually looks for.
                        const p = xy[xy.length - 1];
                        ctx.beginPath();
                        ctx.fillStyle = color;
                        ctx.arc(p[0], p[1], Math.max(3, 0.45 * root.u), 0, 2 * Math.PI);
                        ctx.fill();
                    }

                    line(pts.map(p => p.accuracy), null, null,
                         Qt.rgba(1, 1, 1, 0.16), false);
                    // Fixed axis, so one exceptional stage cannot flatten the
                    // other thirty-nine. km/h is a reciprocal of the reading:
                    // scaled to its own extremes the whole line collapsed into
                    // the bottom of the box.
                    line(pts.map(p => p.median_kmh),
                         root.chart.low_kmh, root.chart.high_kmh,
                         root.theme.gold, true);
                }
            }

            Text {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: 0.8 * root.u
                text: "every stage in order  ·  pace  ·  accuracy"
                color: root.theme.dust
                font.pixelSize: 1.1 * root.u
                opacity: 0.6
            }

            Text {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.topMargin: 2.6 * root.u
                anchors.leftMargin: 0.8 * root.u
                text: root.kmh(root.chart.high_kmh)
                color: root.theme.gold
                font.pixelSize: 1.1 * root.u
                opacity: 0.6
            }

            Text {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 2.6 * root.u
                anchors.leftMargin: 0.8 * root.u
                text: root.kmh(root.chart.low_kmh)
                color: root.theme.gold
                font.pixelSize: 1.1 * root.u
                opacity: 0.6
            }

            Text {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 0.8 * root.u
                text: "quicker is higher"
                color: root.theme.dust
                font.pixelSize: 1.1 * root.u
                opacity: 0.5
            }
        }

        // --- the working ----------------------------------------------------
        Row {
            visible: root.doc.empty !== true
            width: parent.width
            spacing: 2.5 * root.u

            // THEN AND NOW. Two rows, because the comparison is the point and a
            // single "typical time" tells you nothing about direction.
            Column {
                width: (parent.width - 5 * root.u) / 3
                spacing: 0.5 * root.u

                Text {
                    text: "THEN AND NOW"
                    color: root.theme.text
                    font.pixelSize: 1.4 * root.u
                    font.letterSpacing: 3
                    opacity: 0.8
                }

                Repeater {
                    model: root.trend.enough === true
                        ? [root.trend.early, root.trend.recent] : []

                    Rectangle {
                        required property var modelData
                        required property int index
                        width: parent.width
                        height: 6.4 * root.u
                        radius: 0.5 * root.u
                        color: index === 1 ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(0, 0, 0, 0.18)
                        border.width: 1
                        border.color: index === 1 ? Qt.alpha(root.theme.gold, 0.45)
                                                  : Qt.rgba(1, 1, 1, 0.06)

                        Column {
                            anchors.fill: parent
                            anchors.margins: 0.8 * root.u
                            spacing: 0.2 * root.u

                            Text {
                                text: modelData.label
                                color: index === 1 ? root.theme.gold : root.theme.dust
                                font.pixelSize: 1.3 * root.u
                                font.bold: index === 1
                            }
                            Text {
                                text: root.kmh(modelData.median_kmh) + " typical  ·  "
                                      + root.pct(modelData.accuracy) + " correct"
                                color: root.theme.text
                                font.pixelSize: 1.3 * root.u
                            }
                            Text {
                                // A proportion of the pace beside it, not a
                                // km/h width: lib/stats.lua says why the
                                // obvious one is biased against improving.
                                text: "spread " + root.pct(modelData.spread_pct)
                                color: root.theme.dust
                                font.pixelSize: 1.1 * root.u
                                opacity: 0.7
                            }
                        }
                    }
                }

                Text {
                    visible: root.trend.tighter === true
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: "Your answers are clustering tighter, which usually comes before they get quicker."
                    color: root.theme.dust
                    font.pixelSize: 1.1 * root.u
                    opacity: 0.7
                }
            }

            // BY COURSE. Which one is carrying you and which one you avoid.
            Column {
                width: (parent.width - 5 * root.u) / 3
                spacing: 0.5 * root.u

                Text {
                    text: "BY COURSE"
                    color: root.theme.text
                    font.pixelSize: 1.4 * root.u
                    font.letterSpacing: 3
                    opacity: 0.8
                }

                Row {
                    width: parent.width
                    spacing: 0.6 * root.u
                    Text {
                        width: parent.width * 0.44; text: ""
                        font.pixelSize: 1.1 * root.u
                    }
                    Text {
                        width: parent.width * 0.16; text: "stages"
                        color: root.theme.dust; opacity: 0.6
                        font.pixelSize: 1.1 * root.u
                        horizontalAlignment: Text.AlignRight
                    }
                    Text {
                        width: parent.width * 0.16; text: "correct"
                        color: root.theme.dust; opacity: 0.6
                        font.pixelSize: 1.1 * root.u
                        horizontalAlignment: Text.AlignRight
                    }
                    Text {
                        width: parent.width * 0.2; text: "typical"
                        color: root.theme.dust; opacity: 0.6
                        font.pixelSize: 1.1 * root.u
                        horizontalAlignment: Text.AlignRight
                    }
                }

                Repeater {
                    model: root.doc.courses || []

                    Row {
                        required property var modelData
                        width: parent.width
                        spacing: 0.6 * root.u

                        Text {
                            width: parent.width * 0.44
                            text: modelData.label
                            color: root.theme.text
                            font.pixelSize: 1.25 * root.u
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width * 0.16
                            text: modelData.stages
                            color: root.theme.dust
                            font.pixelSize: 1.25 * root.u
                            horizontalAlignment: Text.AlignRight
                        }
                        Text {
                            width: parent.width * 0.16
                            text: root.pct(modelData.accuracy)
                            color: root.theme.dust
                            font.pixelSize: 1.25 * root.u
                            horizontalAlignment: Text.AlignRight
                        }
                        Text {
                            width: parent.width * 0.2
                            text: root.kmh(modelData.median_kmh)
                            color: root.theme.dust
                            font.pixelSize: 1.25 * root.u
                            horizontalAlignment: Text.AlignRight
                        }
                    }
                }

                Item { width: 1; height: 0.6 * root.u }

                Repeater {
                    model: root.doc.records || []

                    Row {
                        required property var modelData
                        width: parent.width
                        spacing: 0.6 * root.u

                        Text {
                            width: parent.width * 0.44
                            text: modelData.label
                            color: root.theme.dust
                            font.pixelSize: 1.2 * root.u
                            opacity: 0.8
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width * 0.52
                            text: modelData.value + "  ·  " + modelData.detail
                            color: root.theme.text
                            font.pixelSize: 1.2 * root.u
                            elide: Text.ElideRight
                        }
                    }
                }
            }

            // YOUR LAST STAGE. What was interesting about the one just played,
            // which is the half of "how am I doing" that a career average
            // cannot answer.
            Column {
                width: (parent.width - 5 * root.u) / 3
                spacing: 0.5 * root.u

                Text {
                    text: "YOUR LAST STAGE"
                    color: root.theme.text
                    font.pixelSize: 1.4 * root.u
                    font.letterSpacing: 3
                    opacity: 0.8
                }

                Text {
                    width: parent.width
                    text: (root.last.label || "-")
                          + (root.last.difficulty ? ("  ·  " + root.last.difficulty) : "")
                          + "  ·  " + (root.last.day || "")
                    color: root.theme.gold
                    font.pixelSize: 1.3 * root.u
                    elide: Text.ElideRight
                }

                Repeater {
                    model: root.last.notes || []

                    Text {
                        required property string modelData
                        width: parent.width
                        text: "·  " + modelData
                        color: root.theme.text
                        font.pixelSize: 1.2 * root.u
                        opacity: 0.85
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }

        // ALL TIME, one line. The career totals are context, not the answer,
        // and giving them their own panel would have said otherwise.
        Text {
            visible: root.doc.empty !== true
            anchors.horizontalCenter: parent.horizontalCenter
            text: (root.lifetime.stages || 0) + " stages  ·  "
                  + (root.lifetime.days || 0) + " days  ·  "
                  + (root.lifetime.correct || 0) + " of " + (root.lifetime.answered || 0)
                  + " answers correct  ·  " + (root.lifetime.clean || 0) + " clean"
            color: root.theme.dust
            font.pixelSize: 1.3 * root.u
            opacity: 0.75
        }

        // HOW TO LEAVE. This surface holds exclusive keyboard focus, so while it
        // is up the whole keymap is dead and Escape is the only key that works.
        Text {
            text: "P saves a picture  ·  ESC to close"
            color: root.theme.dust
            font.pixelSize: 1.3 * root.u
            font.letterSpacing: 2
            opacity: 0.8
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }
}

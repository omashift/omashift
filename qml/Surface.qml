// The Omashift overlay.
//
// A fullscreen Wayland layer surface that renders whatever screen the engine
// says it is on.
//
// IT TAKES NO KEYBOARD FOCUS WHILE THE GAME IS PLAYING. That is the
// load-bearing detail. Capture belongs to the Hyprland submap, which sees every
// key including SUPER; a surface that grabbed focus during a stage would break
// the game rather than display it. It is also why swapping the terminal display
// for this one changes nothing about how the game plays.
//
// The one exception is the end screens, where the submap has already been reset
// and the surface needs a key press to dismiss it. That exception is bounded by
// VISIBILITY, not by which screen is showing, and the distinction is not
// academic: binding focus to the screen alone left an invisible surface holding
// the keyboard after Escape had dismissed it, so the player pressed the key,
// watched the overlay vanish, and still had no keybindings. Trading a submap
// that would not let go for a hidden window that would not let go is not a fix.
//
// An invisible surface must never hold the keyboard.
//
// Pointer input falls through for the same reason: the overlay is a windscreen,
// not a window.

import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: surface

    required property var state
    required property var theme

    readonly property var doc: state.doc
    // NOT `screen`: that is PanelWindow's own property for which monitor this
    // surface lives on. Shadowing it makes it readonly from outside, which
    // silently breaks the per-monitor Variants.
    readonly property string view: state.screen
    readonly property var stage: doc.stage || ({})

    /// Every size below is expressed in these. 1u is 1% of screen height, so a
    /// laptop panel and a 1440p ultrawide get the same composition rather than
    /// the same pixel counts. The first pass used raw pixels and the HUD came
    /// out unreadably small on the wide screen.
    readonly property real u: height / 100
    readonly property real hudUnit: height / 620

    // A screen that is the END of something rather than part of play. These
    // linger in the state file until the next launch, so without a timeout the
    // overlay stays up forever.
    /// A screen you READ and then dismiss, as opposed to one a stage is driving.
    /// Called `terminalScreen` until the terminal display was retired, at which
    /// point the name read as "belongs to the terminal renderer" and meant the
    /// opposite of what it says.
    readonly property bool endScreen:
        ["results", "released", "empty_course", "cabinet", "stats"].indexOf(view) >= 0

    /// SHARED across every monitor's surface, injected by shell.qml. A surface
    /// that owned this itself dismissed only the screen Escape happened to be
    /// focused on and left the other monitor showing a fullscreen results page
    /// over the desktop. Half a dismissal is not a dismissal.
    ///
    /// Set once a terminal screen has been up long enough. THE OVERLAY MUST BE
    /// ABLE TO DISMISS ITSELF.
    ///
    /// It covers the screen and takes no input, so the instruction it used to
    /// print, "omashift --stop closes this", pointed at a terminal the player
    /// could no longer see. Telling someone the way out through the thing
    /// blocking the way out is not an escape hatch, and it stranded a real
    /// player who had finished several stages.
    required property var dismissal
    /// The shell, for calling back to the game. Menu keys have to do something.
    required property var shell

    /// Whether THIS surface is the one that asks for the keyboard. Only one may,
    /// or two surfaces fight over it and keys go missing.
    required property bool focusOwner
    readonly property bool dismissed: dismissal.done

    visible: view !== "" && !dismissed

    // Any change of screen means the game is alive again, so stop hiding.
    onViewChanged: dismissal.done = false

    Timer {
        // Long enough to read a results page without hunting for a key, short
        // enough that a forgotten overlay clears itself before it is a problem.
        // The cabinet is meant to be read and screenshotted, so it gets longer
        // than a results page, which is itself longer than a passing notice.
        interval: (surface.view === "cabinet"
                   || surface.view === "stats") ? 45000
                : surface.view === "results" ? 30000
                : 8000
        running: surface.endScreen && !surface.dismissed
        onTriggered: surface.dismissal.done = true
    }

    // THE BACKSTOP. Any screen that stops changing means the game is gone,
    // whatever screen it happens to be showing.
    //
    // The rule above only covers the screens known to be terminal. A stage that
    // ends without publishing its results page leaves the overlay on a mid-play
    // screen that no timeout covers, and that is not hypothetical: a completed
    // stage was found stuck on the last answer, fullscreen, with the submap
    // already released so nothing on the keyboard could clear it.
    //
    // A live game repaints constantly: prompts, results and countdowns all
    // change within seconds, and a held modifier repaints the HUD. Sixty
    // seconds of a frozen document means nothing is driving it, and it matches
    // the engine's own idle release so the two agree about when a player has
    // gone.
    Timer {
        id: staleWatch
        interval: 60000
        running: surface.visible
        repeat: false
        onTriggered: surface.dismissal.done = true
    }

    // Any write at all, even the same screen with new numbers, is proof the
    // game is alive, so the countdown starts over.
    Connections {
        target: surface.state
        function onDocChanged() {
            surface.dismissal.done = false;
            staleWatch.restart();
        }
    }

    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"

    WlrLayershell.namespace: "omashift"
    WlrLayershell.layer: WlrLayer.Overlay
    // Focus follows VISIBILITY, and only ever on an end screen.
    //
    // `visible` already means "a screen is showing and it has not been
    // dismissed", so the moment Escape sets `dismissed` this drops back to None
    // and the keyboard is released in the same frame. Binding it to
    // `endScreen` alone did not: that stays true after the dismissal, so
    // the surface went invisible while still holding every key.
    /// The welcome screen is a MENU now, so it takes the keyboard like an end
    /// screen does. It is listed separately because dismissing it is only one of
    /// the things its keys can do.
    readonly property bool menuScreen: view === "ready"

    readonly property bool wantsKeys:
        surface.visible && (surface.endScreen || surface.menuScreen) && surface.focusOwner

    WlrLayershell.keyboardFocus: surface.wantsKeys
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Pointer pass-through, EXCEPT on the screens you are meant to dismiss.
    //
    // ASKING FOR KEYBOARD FOCUS IS NOT ENOUGH. During play the whole surface is
    // subtracted from the input region so clicks reach the windows underneath.
    // But an empty input region also makes the surface un-focusable, so
    // `WlrKeyboardFocus.Exclusive` was requested and silently declined, and
    // Escape never arrived. The surface was mapped on both monitors, the focus
    // request was made, and the compositor simply did not honor it. Nothing
    // logged a word about it.
    //
    // So the mask has to lift exactly where focus is wanted. On an end screen
    // that also means the surface swallows clicks, which is correct there: it is
    // a fullscreen page whose only job is to go away, and a click dismisses it
    // too rather than being eaten for nothing.
    mask: (surface.visible && surface.endScreen) ? null : passThrough

    property Region passThrough: Region {
        intersection: Intersection.Subtract
        x: 0; y: 0
        width: surface.width
        height: surface.height
    }

    // ESCAPE CLOSES IT. The results page has no other manual dismissal: by the
    // time it shows, the submap is reset, so the game is not listening to the
    // keyboard any more, and `omashift --stop` needs a terminal that was behind
    // this surface the whole time. Waiting out a 30-second timer was the only
    // option, which is not a dismissal, it is a wait.
    Item {
        id: keys
        anchors.fill: parent
        // Same rule: an invisible surface holds nothing, not even item focus.
        focus: surface.wantsKeys

        // Claim it the moment the surface wants keys, rather than waiting for
        // the binding to settle. The compositor grants keyboard focus
        // asynchronously after the surface maps, so an Escape pressed in that
        // window landed nowhere and read as "Escape did not work the first
        // time". Asking explicitly closes the gap.
        onFocusChanged: if (focus) forceActiveFocus()
        Component.onCompleted: if (focus) forceActiveFocus()
        // Escape is handled in onPressed with everything else, NOT here.
        // Keys.onEscapePressed fires first and unconditionally, which meant the
        // cabinet's "go back to the menu" branch below could never run: Escape
        // left the app before anything got to decide what it should mean.
        // Any key, not just Escape. Someone trying to make a results page go
        // away will press something, and the page has nothing else to offer.
        // A MODIFIER IS NOT A DISMISSAL. Pressing SUPER is the first half of a
        // chord, not a decision to close anything, and treating it as one meant
        // the screen vanished before the second key ever landed. Reaching for
        // any normal shortcut would have killed your results page.
        //
        // Everything else still dismisses: someone trying to make an end screen
        // go away will press something, and the page has nothing else to offer.
        Keys.onPressed: function(event) {
            switch (event.key) {
            case Qt.Key_Shift: case Qt.Key_Control: case Qt.Key_Alt:
            case Qt.Key_Meta:  case Qt.Key_AltGr:   case Qt.Key_Super_L:
            case Qt.Key_Super_R: case Qt.Key_CapsLock: case Qt.Key_NumLock:
            case Qt.Key_ScrollLock:
                return;                 // let it through; it may be part of a chord
            }

            // P SAVES A PICTURE, and so does PRINT. Neither dismisses.
            //
            // Checked before everything else, because the rule below is that
            // any key closes an end screen, and the Cabinet and the Logbook are
            // precisely the screens somebody wants to keep. This surface holds
            // exclusive keyboard focus, so the player's own screenshot binding
            // is swallowed and the game has to offer the shortcut itself.
            //
            // P IS THE ONE THAT IS ADVERTISED, because plenty of keyboards do
            // not have a PrintScreen key at all. A 75% or 84-key board puts it
            // on a function layer or leaves it out, and a Mac-oriented one may
            // not send the keysym in any layer. Depending on it meant the two
            // screens this game exists to be screenshotted from could not be
            // screenshotted on the keyboard in front of me.
            if (event.key === Qt.Key_P || event.key === Qt.Key_Print) {
                surface.shell.snapshot(surface.view);
                event.accepted = true;
                return;
            }

            // On the MENU, keys mean things. Anywhere else, any key closes.
            //
            // The welcome screen used to be the one place in the game with no
            // way out: it took no keyboard, so Escape did nothing, and the only
            // route onward was to play. A game you cannot leave from its own
            // front door is a trap, however good the game is.
            if (surface.menuScreen) {
                switch (event.key) {
                case Qt.Key_Return: case Qt.Key_Enter:
                    surface.shell.ask("--go"); break;
                // C is Courses and T is Trophies. Both are what the thing is
                // called, which beats a mnemonic you have to be told.
                case Qt.Key_C:
                    surface.shell.ask2("--cycle-course", "next"); break;
                case Qt.Key_T:
                    surface.shell.ask("--cabinet"); break;
                case Qt.Key_S:
                    surface.shell.ask("--stats"); break;
                case Qt.Key_D:
                    surface.shell.ask("--cycle-difficulty"); break;
                // Arrows change VALUES, letters go to DESTINATIONS. T is the
                // Trophies and S is the Stats, both named after the thing they
                // open, which beats a mnemonic you have to be told. A length is
                // a position in a list, so it moves with the arrows.
                case Qt.Key_Up:
                    surface.shell.ask2("--cycle-length", "up"); break;
                case Qt.Key_Down:
                    surface.shell.ask2("--cycle-length", "down"); break;
                case Qt.Key_Escape:
                    surface.dismissal.done = true; break;
                default:
                    return;             // an unknown key on a menu does nothing
                }
                event.accepted = true;
                return;
            }

            // A screen that says where BACK goes, goes back. The cabinet
            // opened from the menu returns to it, the way any game's trophy
            // case does; opened on its own from a terminal there is nothing to
            // return to, so it leaves like every other end screen.
            if (event.key === Qt.Key_Escape && surface.doc.back === "menu") {
                surface.shell.ask("--menu");
                event.accepted = true;
                return;
            }

            // ENTER GOES AGAIN, from the results page only.
            //
            // Wanting another stage is the ordinary thing to want there, and
            // sending it through the menu made the core loop cost two presses
            // and a screen nobody asked to see. Same course, same length, same
            // difficulty: the decision was already made before the last stage.
            //
            // Only where there is something to repeat. On the Cabinet or the
            // Logbook, ENTER falls through and dismisses like any other key.
            if (surface.view === "results"
                && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                surface.shell.ask("--again");
                event.accepted = true;
                return;
            }

            surface.dismissal.done = true;
            event.accepted = true;
        }

        // The mask is lifted on these screens, so clicks land here instead of
        // passing through. Eating them silently would be worse than either
        // extreme; dismissing is what someone clicking a results page wants.
        MouseArea {
            anchors.fill: parent
            enabled: surface.visible && surface.endScreen
            onClicked: surface.dismissal.done = true
        }
    }

    /// The course's backdrop, when it has one. The engine resolves it to a path
    /// that exists, so a theme this machine does not have simply arrives as
    /// nothing and the drawn sky below carries the screen instead.
    readonly property var scene: (doc.scene) || (doc.stage && doc.stage.scene) || null

    // NOTHING SEES THROUGH THIS SURFACE, EVER.
    //
    // The floor under every backdrop. Changing course changes the wallpaper, and
    // a wallpaper is decoded asynchronously, so for a frame or two there was
    // nothing painted at all and the desktop showed through the middle of the
    // game. Even with the crossfade below, one opaque rectangle is the
    // difference between a worst case of "a plain dark panel" and a worst case
    // of "your desktop, briefly, while a menu is open".
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0.06, 0.03, 0.08, 1)
    }

    // The sky is the fallback, not the default. It draws whenever no course has
    // claimed the screen, which is every screen the game had before courses grew
    // scenery, so nothing is lost when a theme is missing.
    Sky {
        anchors.fill: parent
        visible: !surface.scene
        theme: surface.theme
    }

    // TWO IMAGES, CROSSFADED. One would have to blank itself to load the next.
    //
    // The new wallpaper is decoded in the back layer while the old one is still
    // on screen, and only once it is READY does the swap happen. Pressing C on
    // the menu used to flash the desktop through the gap; now the picture
    // changes as if that were the intention.
    Item {
        id: backdrop
        anchors.fill: parent
        visible: !!surface.scene

        /// The path currently PAINTED, as opposed to the one most recently
        /// asked for. They differ for exactly as long as a decode takes.
        property string shown: ""
        property string wanted: surface.scene ? ("file://" + surface.scene.image) : ""
        /// Which of the two layers holds `shown`. The other is the loader.
        property bool frontIsA: true

        Component.onCompleted: prime()

        function prime() {
            if (wanted === shown) return;
            // First picture of the session: nothing to fade from, so take it.
            if (shown === "") {
                shown = wanted;
                (frontIsA ? layerA : layerB).source = wanted;
                return;
            }
            (frontIsA ? layerB : layerA).source = wanted;
        }

        onWantedChanged: prime()

        function settle(layer, isA) {
            if (layer.status !== Image.Ready) return;
            if (layer.source.toString() !== wanted) return;
            shown = wanted;
            frontIsA = isA;
        }

        Image {
            id: layerA
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            // Capped to the surface. These are wallpapers: the winding road is
            // 6016x3384, which is 20 megapixels decoded into a texture for a
            // 1920 wide panel. Decoding at the size actually drawn costs nothing
            // visually and avoids holding several of them in memory at once.
            sourceSize.width: surface.width
            sourceSize.height: surface.height
            opacity: backdrop.frontIsA ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 220 } }
            onStatusChanged: backdrop.settle(layerA, true)
        }

        Image {
            id: layerB
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            sourceSize.width: surface.width
            sourceSize.height: surface.height
            opacity: backdrop.frontIsA ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 220 } }
            onStatusChanged: backdrop.settle(layerB, false)
        }
    }

    // The scrim, carried per course rather than fixed.
    //
    // One value cannot serve a Brueghel and a black moon. The commute's carts on
    // a path are bright and busy and need 0.78 to read over; the ship at sea is
    // already almost black and only wants 0.52. Every screen that has ever been
    // unreadable in this project was unreadable because something pretty was
    // competing with the words.
    Rectangle {
        anchors.fill: parent
        visible: !!surface.scene
        color: Qt.rgba(0.06, 0.03, 0.08, surface.scene ? surface.scene.scrim : 0.6)
    }

    // --- the running HUD ----------------------------------------------------
    // Shown for every in-play screen, so the frame does not jump between a
    // prompt and its result.
    readonly property bool playing: ["countdown", "prompt", "result"].indexOf(view) >= 0

    Item {
        anchors.fill: parent
        visible: surface.playing

        // Stage, gear, points across the top.
        Row {
            id: topBar
            anchors { top: parent.top; topMargin: 4 * u; horizontalCenter: parent.horizontalCenter }
            spacing: 6 * u

            Column {
                Text {
                    text: "STAGE"; color: theme.dust; font.pixelSize: 1.3 * u; font.letterSpacing: 3
                }
                Text {
                    text: (stage.index || 0) + " / " + (stage.total || 0)
                    color: theme.text; font.pixelSize: 3.4 * u; font.bold: true
                }
            }
            Column {
                Text { text: "GEAR"; color: theme.dust; font.pixelSize: 1.3 * u; font.letterSpacing: 3 }
                Row {
                    spacing: 6
                    Repeater {
                        model: stage.max_gear || 4
                        Rectangle {
                            width: 1.8 * u; height: 2.9 * u; radius: 3
                            // Gears below the current one stay lit, so the bar
                            // reads as a position rather than a single marker.
                            color: (index < (stage.gear || 1)) ? theme.apex : "transparent"
                            border.width: 2
                            border.color: Qt.rgba(theme.dust.r, theme.dust.g, theme.dust.b, 0.4)
                            Behavior on color { ColorAnimation { duration: 120 } }
                        }
                    }
                }
            }
            Column {
                Text { text: "POINTS"; color: theme.dust; font.pixelSize: 1.3 * u; font.letterSpacing: 3 }
                Text {
                    text: stage.points || 0
                    color: theme.text; font.pixelSize: 3.4 * u; font.bold: true
                }
            }
            Column {
                visible: !!stage.assisted
                Text { text: "CO-DRIVER"; color: theme.dust; font.pixelSize: 1.3 * u; font.letterSpacing: 3 }
                Text { text: "calling"; color: theme.apex; font.pixelSize: 2 * u }
            }
        }

        Wheels {
            id: wheels
            theme: surface.theme
            unit: surface.hudUnit
            held: doc.held || ({})
            quattro: !!doc.quattro
            anchors { right: parent.right; rightMargin: 3 * u; verticalCenter: parent.verticalCenter }
        }
    }

    // --- the pace note ------------------------------------------------------
    // A scrim, because the sky is at its brightest exactly where the text sits
    // and legibility is not negotiable for the one word the player must read.
    Rectangle {
        anchors.centerIn: parent
        width: parent.width
        height: (view === "result" || view === "ready") ? 52 * u : 34 * u
        visible: ["prompt", "result", "ready", "countdown", "released", "empty_course"]
                 .indexOf(view) >= 0
        gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.5; color: Qt.rgba(0.11, 0.05, 0.12, 0.72) }
            GradientStop { position: 1.0; color: "transparent" }
        }
    }

    Column {
        anchors.centerIn: parent
        spacing: 18
        visible: view === "prompt"

        Text {
            text: "PACE NOTE"
            color: theme.dust
            font.pixelSize: 1.5 * u; font.letterSpacing: 6
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
            text: (doc.prompt && doc.prompt.description) || ""
            color: theme.text
            font.pixelSize: 6 * u; font.bold: true
            anchors.horizontalCenter: parent.horizontalCenter
        }
        // The co-driver. Its LEVEL is styled, not just its text: "modifiers
        // revealed" is a nudge, "the whole combo" is the answer, and they should
        // not look alike.
        Text {
            visible: !!doc.hint
            text: (doc.hint && doc.hint.text) || ""
            color: (doc.hint && doc.hint.level === "full") ? theme.gold : theme.apex
            font.pixelSize: (doc.hint && doc.hint.level === "full") ? 3.6 * u : 2.8 * u
            font.letterSpacing: 2
            anchors.horizontalCenter: parent.horizontalCenter
        }

        // A key that matches nothing in your keymap. While a stage runs the
        // submap has replaced every binding, so such a key is not wrong, it is
        // SWALLOWED: the game received the press and had nothing to do with it.
        // Saying so is the difference between a game that ignored you and a
        // game that has stopped responding.
        Text {
            visible: doc.unbound === true
            text: "that key does nothing during a stage"
            color: theme.dust
            font.pixelSize: 1.8 * u
            font.letterSpacing: 1
            opacity: 0.8
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }

    // --- the result ---------------------------------------------------------
    Column {
        anchors.centerIn: parent
        spacing: 14
        visible: view === "result"

        readonly property var r: doc.result || ({})

        Text {
            text: parent.r.praise || (parent.r.tier || "").toUpperCase()
            color: parent.r.outcome === "correct" ? theme.tierColor(parent.r.tier) : theme.off
            font.pixelSize: 4.6 * u; font.bold: true; font.letterSpacing: 2
            anchors.horizontalCenter: parent.horizontalCenter
            visible: parent.r.outcome === "correct"
        }
        Text {
            text: "OFF, into the scenery"
            color: theme.off
            font.pixelSize: 4.6 * u; font.bold: true
            anchors.horizontalCenter: parent.horizontalCenter
            visible: parent.r.outcome === "off"
        }
        // A skip is not a crash and must not be announced as one. The player
        // did not get this wrong, they declined it, usually because their
        // keyboard cannot produce the chord at all.
        Text {
            text: "SKIPPED"
            color: theme.dust
            font.pixelSize: 4.6 * u; font.bold: true; font.letterSpacing: 4
            anchors.horizontalCenter: parent.horizontalCenter
            visible: parent.r.outcome === "skipped"
        }
        // NOTHING LEAVES YOUR ROTATION WITHOUT YOU BEING TOLD. The second
        // skip of an action retires it, and that is said at the moment it
        // happens rather than left for the player to notice as an absence.
        Text {
            text: parent.r.retired
                ? "that is twice, so it leaves the rotation"
                : "this one will not come back"
            color: theme.dust
            font.pixelSize: 1.8 * u
            opacity: 0.75
            anchors.horizontalCenter: parent.horizontalCenter
            visible: parent.r.outcome === "skipped"
        }
        Text {
            text: (parent.r.speed_kmh || 0) + " km/h"
            color: theme.speedColor(parent.r.speed_kmh || 0)
            font.pixelSize: 8 * u; font.bold: true
            // Not for a skip. Zero is the right speed for an off, because you
            // are in the scenery; on a note you declined it is a scoreboard
            // shouting a failure that did not happen.
            visible: parent.r.outcome !== "skipped"
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
            visible: parent.r.ghost_gap_s !== undefined
            text: parent.r.best
                  ? "NEW BEST  " + (parent.r.ghost_gap_s || 0).toFixed(2) + "s"
                  : "ghost " + (parent.r.ghost_kmh || 0) + " km/h   "
                    + ((parent.r.ghost_gap_s || 0) > 0 ? "+" : "")
                    + (parent.r.ghost_gap_s || 0).toFixed(2) + "s"
            color: parent.r.best ? theme.gold : theme.dust
            font.pixelSize: 2.1 * u
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
            text: (parent.r.expected || "") + "   ·   " + (parent.r.description || "")
            color: theme.dust
            font.pixelSize: 2 * u
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
            visible: !!parent.r.pressed
            text: "you pressed " + (parent.r.pressed || "")
                  + (parent.r.pressed_was ? "  ·  " + parent.r.pressed_was : "")
            color: theme.off
            font.pixelSize: 1.7 * u
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }

    // --- the way out --------------------------------------------------------
    //
    // THE OVERLAY MUST TELL YOU HOW TO LEAVE. It never did, and that is the
    // in-play twin of the bug the dismiss timers above were written for: during
    // a stage every keybinding is a game answer, so `omashift --stop` needs a
    // terminal the player cannot open, and the only chord that works was
    // printed by the terminal display and nowhere else. A player on this
    // overlay had no way to find it.
    //
    // The chord comes from the model, never a literal here. A hint naming a
    // chord nothing is bound to is worse than no hint at all.
    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 3 * u
        spacing: 0.6 * u
        visible: view === "prompt"

        Text {
            visible: !!doc.skip_key
            text: (doc.skip_key || "") + "  to skip this note"
            color: theme.dust
            font.pixelSize: 1.4 * u
            font.letterSpacing: 2
            opacity: 0.75
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
            visible: !!doc.retire_key
            text: (doc.retire_key || "") + "  to retire"
            color: theme.dust
            font.pixelSize: 1.4 * u
            font.letterSpacing: 2
            opacity: 0.75
            anchors.horizontalCenter: parent.horizontalCenter
        }

        // THE CLOCK. A screen that will not move on, on a note you cannot
        // answer, reads as a hung machine. This says the keyboard comes back by
        // itself and exactly when, so waiting becomes a decision rather than a
        // gamble. It appears only when it is close enough to matter.
        Text {
            visible: doc.release_in_s !== undefined && doc.release_in_s !== null
            text: "your keys come back on their own in " + (doc.release_in_s || 0) + "s"
            color: (doc.release_in_s || 99) <= 10 ? theme.hot : theme.dust
            font.pixelSize: 1.6 * u
            font.letterSpacing: 1
            opacity: 0.9
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }

    // --- the cabinet --------------------------------------------------------
    Cabinet {
        anchors.fill: parent
        visible: view === "cabinet"
        doc: surface.doc
        theme: surface.theme
        u: surface.u
    }

    // --- loading ------------------------------------------------------------
    //
    // The first frame anyone sees, and until now it drew nothing at all: the
    // overlay came up on a bare backdrop for as long as it took to read the
    // keymap and render the menu. A blank wallpaper is indistinguishable from a
    // game that failed to start, which is a poor first impression from the one
    // screen every single launch goes through.
    Column {
        anchors.centerIn: parent
        spacing: 3 * u
        visible: view === "loaded"

        Wordmark {
            ink: theme.gold
            cell: 1.15 * u
            anchors.horizontalCenter: parent.horizontalCenter
        }

        Text {
            text: (doc.bindings || 0) + " bindings in the bank"
            color: theme.dust
            font.pixelSize: 1.8 * u
            font.letterSpacing: 2
            opacity: 0.8
            anchors.horizontalCenter: parent.horizontalCenter
        }

        // THE PATRON, ONCE, AS THE CAR ROLLS OUT.
        //
        // This screen and no other. It is up for about a second at launch and
        // is replaced by the menu, which is what makes it livery rather than an
        // advertisement: a sponsor mark on the car is expected, the same mark on
        // the trophy you just won is not. It is deliberately absent from the
        // results page, the Cabinet and the Logbook, which are the screens
        // people screenshot and the ones that belong to the player.
        //
        // "Patron" and not "sponsored by". Four did not buy this placement, and
        // the word that describes the relationship accurately is also the one
        // this project already uses: the trophy names are homage to patrons of
        // Omarchy, and this is the same register.
        //
        // The rule it obeys is the project's own, written when using the mark's
        // four dots as the modifier HUD was rejected: a FUNCTIONAL element
        // carrying a company mark is product placement rather than homage. This
        // element does nothing.
        Row {
            spacing: 1.1 * u
            anchors.horizontalCenter: parent.horizontalCenter
            opacity: 0.55

            Text {
                text: "patron"
                color: theme.dust
                font.pixelSize: 1.3 * u
                font.letterSpacing: 3
                anchors.verticalCenter: parent.verticalCenter
            }
            FourMark {
                size: 1.9 * u
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: "Four"
                color: theme.dust
                font.pixelSize: 1.5 * u
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    // --- the logbook --------------------------------------------------------
    Stats {
        anchors.fill: parent
        visible: view === "stats"
        doc: surface.doc
        theme: surface.theme
        u: surface.u
    }

    // --- countdown ----------------------------------------------------------
    Text {
        anchors.centerIn: parent
        visible: view === "countdown"
        text: doc.lfg ? "LFG!!!!" : (doc.n || "")
        color: doc.lfg ? theme.gold : theme.text
        font.pixelSize: doc.lfg ? 10 * u : 22 * u
        font.bold: true
        font.letterSpacing: doc.lfg ? 8 : 0
    }

    // --- ready --------------------------------------------------------------
    // A scrim, the third screen to need one and for the same reason every time:
    // the sky is at its brightest exactly where the text sits. The pace note has
    // one, the cabinet has one, and the menu's footer was unreadable without it.
    Rectangle {
        anchors.fill: parent
        visible: view === "ready"
        color: Qt.rgba(0.11, 0.05, 0.12, 0.62)
    }

    Column {
        anchors.centerIn: parent
        spacing: 20
        visible: view === "ready"

        // ATTRACT MODE. The front screen is the one place in the game where
        // nothing is being timed and the player's own keybindings are still
        // live, so it is the one place a logo can move without costing anyone
        // anything. Generated from assets/make-logo.py, the same source as the
        // wordmark on the launch page, because two drawings of one mark drift
        // and the drift is invisible until they are side by side.
        Wordmark {
            ink: theme.gold
            cell: 1.15 * u
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
            text: (doc.course || "") + "   ·   " + (doc.difficulty || "")
                  + "   ·   " + (doc.notes || 0) + " pace notes"
            color: theme.text; font.pixelSize: 2.3 * u
            anchors.horizontalCenter: parent.horizontalCenter
        }
        // THE MENU. A game's front door should say what it accepts, and this one
        // said "press the same key again" and nothing else: no way to the
        // cabinet, no way to change anything, and no way out at all.
        //
        // Every key here is bare on purpose. The bank has no bare letters in it,
        // and this screen holds the keyboard, so nothing collides.
        Grid {
            columns: 2
            rowSpacing: 1.2 * u
            columnSpacing: 2.5 * u
            anchors.horizontalCenter: parent.horizontalCenter

            Text {
                text: "ENTER"; color: theme.gold
                font.pixelSize: 2.2 * u; font.bold: true
                horizontalAlignment: Text.AlignRight; width: 12 * u
            }
            Text { text: "start the stage"; color: theme.text; font.pixelSize: 2.2 * u }

            Text {
                text: "C"; color: theme.apex
                font.pixelSize: 2.2 * u; font.bold: true
                horizontalAlignment: Text.AlignRight; width: 12 * u
            }
            Text {
                text: "course  ·  " + (doc.course || "all bindings")
                color: theme.text; font.pixelSize: 2.2 * u
            }

            Text {
                text: "\u2191 \u2193"; color: theme.apex
                font.pixelSize: 2.2 * u; font.bold: true
                horizontalAlignment: Text.AlignRight; width: 12 * u
            }
            Text {
                text: "pace notes  ·  " + (doc.notes || 0)
                color: theme.text; font.pixelSize: 2.2 * u
            }

            Text {
                text: "D"; color: theme.apex
                font.pixelSize: 2.2 * u; font.bold: true
                horizontalAlignment: Text.AlignRight; width: 12 * u
            }
            Text {
                text: "difficulty  ·  " + (doc.difficulty || "medium")
                color: theme.text; font.pixelSize: 2.2 * u
            }

            Text {
                text: "T"; color: theme.apex
                font.pixelSize: 2.2 * u; font.bold: true
                horizontalAlignment: Text.AlignRight; width: 12 * u
            }
            Text { text: "trophies"; color: theme.text; font.pixelSize: 2.2 * u }

            Text {
                text: "S"; color: theme.apex
                font.pixelSize: 2.2 * u; font.bold: true
                horizontalAlignment: Text.AlignRight; width: 12 * u
            }
            // A key the menu answers to and does not list is a key nobody
            // presses. The whole reason the menu exists is that the game had
            // destinations you could only reach by knowing they were there.
            Text { text: "stats"; color: theme.text; font.pixelSize: 2.2 * u }

            Text {
                text: "ESC"; color: theme.hot
                font.pixelSize: 2.2 * u; font.bold: true
                horizontalAlignment: Text.AlignRight; width: 12 * u
            }
            Text { text: "leave"; color: theme.text; font.pixelSize: 2.2 * u }
        }

        Text {
            // The chord still launches from the desktop; it just cannot start a
            // stage from here any more, because this screen holds the keyboard.
            // ENTER replaces the second press, which is what buys the menu.
            text: "this screen has the keyboard  ·  " + (doc.launch_key || "") + " opened it"
            color: theme.dust; font.pixelSize: 1.5 * u; opacity: 0.7
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }

    // --- released / nothing to drill ----------------------------------------
    Column {
        anchors.centerIn: parent
        spacing: 14
        visible: view === "released" || view === "empty_course"

        Text {
            text: view === "released"
                  ? (doc.reason === "idle"
                     ? "released after " + (doc.after_s || 0) + " seconds idle"
                     : "retired")
                  : "nothing to drill yet"
            color: theme.text; font.pixelSize: 4.2 * u; font.bold: true
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
            // Two ways to be empty. A dynamic course has nothing to say YET; a
            // curated one matched nothing in this keymap, which playing more
            // will not fix.
            text: view === "released"
                  ? "your keybindings are back"
                  : doc.dynamic
                    ? "play a few stages first. this course is built from what you miss"
                    : "nothing in your keymap matches this course. Courses match on what a binding is described as doing, so try another, or omashift --all"
            color: theme.dust; font.pixelSize: 2 * u
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }

    // --- the results page ---------------------------------------------------
    // A PANEL, not a scrim. This is the screen a player sits on longest and the
    // only one that is a document rather than a moment, so it gets a surface to
    // sit on instead of fighting the sky for contrast, which the first pass
    // lost badly, with the ladder and trophies unreadable over the sun.
    Item {
        id: resultsPage
        anchors.fill: parent
        visible: view === "results"
        readonly property var s: doc.summary || ({})

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width * 0.62, 96 * u)
            height: card.implicitHeight + 8 * u
            radius: 2 * u
            color: Qt.rgba(theme.ground.r, theme.ground.g, theme.ground.b, 0.9)
            border.width: 2
            border.color: Qt.rgba(theme.hills.r, theme.hills.g, theme.hills.b, 0.6)

            Column {
                id: card
                anchors.centerIn: parent
                width: parent.width - 8 * u
                spacing: 2.4 * u

                Text {
                    text: "STAGE COMPLETE"
                    color: theme.gold
                    font.pixelSize: 4.2 * u; font.bold: true; font.letterSpacing: 8
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                // The headline four, evenly spread rather than clustered.
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 7 * u

                    component Stat: Column {
                        property string label: ""
                        property string value: ""
                        property color tone: theme.text
                        Text {
                            text: parent.label; color: theme.dust
                            font.pixelSize: 1.3 * u; font.letterSpacing: 3
                        }
                        Text {
                            text: parent.value; color: parent.tone
                            font.pixelSize: 4 * u; font.bold: true
                        }
                    }

                    Stat {
                        label: "CORRECT"
                        value: (resultsPage.s.correct || 0) + " / " + (resultsPage.s.prompts || 0)
                    }
                    Stat {
                        label: "AVG SPEED"
                        value: (resultsPage.s.average_kmh || 0) + " km/h"
                        // On a dark panel the speed ramp reads; over the sky it
                        // did not, which is half of why this became a panel.
                        tone: theme.speedColor(resultsPage.s.average_kmh || 0)
                    }
                    Stat {
                        label: "TOP SPEED"
                        value: (resultsPage.s.top_kmh || 0) + " km/h"
                        tone: theme.gold
                    }
                    Stat { label: "POINTS"; value: String(resultsPage.s.points || 0) }
                }

                Text {
                    visible: resultsPage.s.ghost_gap_s !== undefined
                    text: "vs ghost   " + ((resultsPage.s.ghost_gap_s || 0) > 0 ? "+" : "")
                          + (resultsPage.s.ghost_gap_s || 0).toFixed(2) + "s over "
                          + (resultsPage.s.ghost_notes || 0) + " notes   ("
                          + (resultsPage.s.ghost_beat || 0) + " beaten)"
                    color: (resultsPage.s.ghost_gap_s || 0) < 0 ? theme.apex : theme.dust
                    font.pixelSize: 1.9 * u
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                // The ladder. This is the readout that makes a difficulty change
                // visible rather than merely claimed, so it gets real width.
                Column {
                    spacing: 0.9 * u
                    anchors.horizontalCenter: parent.horizontalCenter
                    Repeater {
                        model: doc.ladder || []
                        Row {
                            spacing: 1.4 * u
                            Text {
                                text: modelData.name
                                color: theme.tierColor(modelData.name)
                                font.pixelSize: 1.7 * u
                                width: 14 * u
                                horizontalAlignment: Text.AlignRight
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            // A track behind the bar, so an empty tier still
                            // reads as a tier you did not reach rather than a
                            // missing row.
                            Rectangle {
                                width: 34 * u
                                height: 1.8 * u
                                radius: 2
                                color: Qt.rgba(theme.dust.r, theme.dust.g, theme.dust.b, 0.12)
                                anchors.verticalCenter: parent.verticalCenter
                                Rectangle {
                                    width: parent.width * (modelData.share || 0)
                                    height: parent.height
                                    radius: 2
                                    color: theme.tierColor(modelData.name)
                                }
                            }
                            Text {
                                text: modelData.count || 0
                                color: theme.dust; font.pixelSize: 1.7 * u
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }
                }

                Repeater {
                    model: doc.trophies || []
                    Text {
                        text: "TROPHY   " + modelData.phrase
                              + (modelData.tier ? "  (" + modelData.tier + ")" : "")
                        color: theme.gold; font.pixelSize: 2.1 * u; font.bold: true
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                }

                Text {
                    // NOT "your keys are back", and not SUPER+ALT+O either.
                    //
                    // This surface holds exclusive keyboard focus while it is
                    // up, which swallows Hyprland's own shortcuts: SUPER+RETURN
                    // opens nothing and SUPER+W closes nothing. Escape is the
                    // only key that works. Telling a player to press a chord
                    // that physically cannot fire is worse than saying nothing,
                    // and it read as a bug in the game rather than in the text.
                    //
                    // The terminal display says something different on purpose:
                    // it is a window, it takes no focus, and there the keyboard
                    // really is back.
                    // And P, because this surface swallows the player's own
                    // screenshot binding along with everything else, on one of
                    // the three screens anybody would want to keep. A letter
                    // rather than PRINT: a compact keyboard may not have that
                    // key at all, and this one is on every board there is.
                    text: "ENTER goes again  ·  ESC back to the menu  ·  P saves a picture"
                    color: theme.dust; font.pixelSize: 1.6 * u
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }
}

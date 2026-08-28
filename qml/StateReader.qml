// Watches the engine's structured state file and exposes it as a parsed object.
//
// The engine writes /tmp/omashift-state.json on every screen change. That file
// is the ENTIRE interface between the game and this display: nothing here talks
// to Hyprland, reads a key, or knows what a submap is. Capture belongs to the
// engine, which is why swapping the terminal display for this one changes
// nothing about how the game plays.
//
// Rooted at QtObject rather than Item on purpose: Item has a builtin `state`
// property whose auto-generated signal Quickshell rejects as a duplicate.

import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root

    /// The parsed state document. Always an object, never null, so every
    /// consumer can read `doc.screen` without a guard.
    property var doc: ({ screen: "" })

    /// Which screen the engine is showing. "" means nothing is running.
    readonly property string screen: doc.screen || ""

    property string statePath: {
        const env = Quickshell.env("OMASHIFT_STATE_JSON");
        return (env && env.length > 0) ? env : "/tmp/omashift-state.json";
    }

    /// How long the opening frame stays up, at minimum.
    ///
    /// IT USED TO BE AN ACCIDENT. The loading frame was on screen for exactly as
    /// long as the launcher took to get from loading the engine to rendering the
    /// menu, measured at 1.55s, which is not a decision anybody made and would
    /// drift with the size of the keymap and the speed of the machine.
    ///
    /// Enforced HERE rather than by a sleep in the launcher, because this is the
    /// only place that knows when the frame actually reached the screen.
    /// Quickshell takes a moment to start and paint, so a delay measured in the
    /// launcher is a delay to something nobody is looking at yet.
    ///
    /// A MINIMUM, not a duration. The launcher is already working through most
    /// of it, so the wait this adds is the difference, and the menu appears the
    /// instant it is up. Nothing about the game is held back: the engine has
    /// loaded and the stage is armed while this is on screen.
    property int introMs: 3000

    property double _introShownAt: 0
    property var _pending: null

    property Timer _introHold: Timer {
        repeat: false
        onTriggered: {
            if (root._pending) {
                root.doc = root._pending;
                root._pending = null;
            }
        }
    }

    /// Take a document, unless the opening frame has not had its moment.
    function _accept(next) {
        const wasIntro = (root.doc.screen || "") === "loaded";
        const nowIntro = (next.screen || "") === "loaded";

        if (nowIntro && !wasIntro) {
            root._introShownAt = Date.now();
            root.doc = next;
            return;
        }

        if (wasIntro && !nowIntro) {
            const left = root.introMs - (Date.now() - root._introShownAt);
            if (left > 0) {
                // Hold the newest, not a queue. If three documents arrive during
                // the intro, the player should land on the last one, not watch
                // the first two flash past.
                root._pending = next;
                root._introHold.interval = left;
                root._introHold.restart();
                return;
            }
        }

        root._pending = null;
        root._introHold.stop();
        root.doc = next;
    }

    property FileView _fileView: FileView {
        path: root.statePath
        watchChanges: true
        printErrors: false

        onLoaded: {
            // A file being rewritten can be read mid-write, so a parse failure
            // is expected traffic rather than an error. Keep the last good
            // document: a half-drawn frame is better than a blank screen.
            try {
                const next = JSON.parse(text());
                if (next && typeof next === "object") {
                    root._accept(next);
                }
            } catch (e) {
                // Deliberately silent. The next write will be complete.
            }
        }

        // No file means no game. Clearing the document is what hides the
        // overlay, which is how `omashift --stop` puts it away.
        // No file means no game, and that outranks the intro: `omashift --stop`
        // has to put the overlay away immediately, not after a countdown.
        onLoadFailed: {
            root._pending = null;
            root._introHold.stop();
            root.doc = ({ screen: "" });
        }
        onFileChanged: reload()
    }
}

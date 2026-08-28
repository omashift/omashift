// Watches the engine's structured state file and exposes it as a parsed object.
//
// The engine writes state.json in the private runtime directory on every
// screen change, and lib/runtime.lua is where that path is decided. That file
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

    // $XDG_RUNTIME_DIR is 0700 and per user, so this file is not reachable by
    // anybody who could abuse it. It used to be /tmp/omashift-state.json, which
    // any local process could predict, pre-place, or replace. See
    // lib/runtime.lua for the whole argument.
    property string statePath: {
        const env = Quickshell.env("OMASHIFT_STATE_JSON");
        if (env && env.length > 0)
            return env;
        const run = Quickshell.env("XDG_RUNTIME_DIR");
        return (run && run.length > 0)
            ? run + "/omashift/state.json"
            : "";
    }

    /// The most a screen is ever allowed to be.
    ///
    /// FileView cannot stat: Quickshell exposes path, text, data and the watch
    /// flags, and nothing that reports type, owner, or size. So the boundary is
    /// the 0700 directory above, and this is the one check a reader can make on
    /// its own. A state document is a screen; anything near this cap is not one.
    readonly property int maxStateBytes: 262144

    /// Every screen the engine can publish, and nothing else is accepted.
    ///
    /// THE DIRECTORY STOPS ANOTHER USER, NOT ANOTHER PROCESS OF YOURS. A 0700
    /// runtime directory is closed to everybody but you, and open to every
    /// process running as you. No file check closes that: their file is owned
    /// by you, so an owner test passes, and any nonce we could sign with is
    /// readable by them too.
    ///
    /// So this reader stops trying to prove who wrote the document and bounds
    /// what an unexpected one can do instead. A document naming a screen the
    /// engine cannot produce is dropped whole, which also keeps its other
    /// fields from reaching anything downstream.
    ///
    /// The bar widget answered the same question by not reading at all, which
    /// it could afford and this cannot: this IS the display. It runs in the
    /// game's own process, so the worst case here is a frame, not the bar.
    readonly property var knownScreens: [
        "loaded", "ready", "countdown", "prompt", "result", "results",
        "released", "cabinet", "stats", "empty_course"
    ]

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
                const raw = text();
                // Refused rather than parsed. Keeping the last good document is
                // already what this handler does on a bad parse, so an oversized
                // one costs a frame and nothing else.
                if (raw.length > root.maxStateBytes)
                    return;
                const next = JSON.parse(raw);
                if (!next || typeof next !== "object" || Array.isArray(next))
                    return;
                // Dropped WHOLE on an unknown screen, not blanked: a document
                // this reader does not recognize should not get to set any
                // field, and blanking would hide the overlay on a half write.
                if (root.knownScreens.indexOf(String(next.screen || "")) < 0)
                    return;
                root._accept(next);
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

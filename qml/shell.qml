// Omashift's Quickshell display.
//
// Run standalone rather than as part of Omarchy's shell:
//
//   quickshell -p <checkout>/qml/shell.qml
//
// Standalone on purpose. The game is a transient thing that takes over the
// screen and then goes away; wiring it into the user's persistent shell would
// mean a crash here could take their bar and notifications with it.
//
// One surface per monitor. A fullscreen game on a two-monitor desk should not
// pick one and leave the other showing a half-covered desktop.

import QtQuick
import Quickshell

ShellRoot {
    id: shellRoot

    // One reader, shared. Every surface renders the same engine state, so they
    // stay in lockstep without any coordination between them.
    StateReader { id: engineState }

    Theme { id: quattro }

    // Dismissal is SHARED, for exactly the reason the state reader is.
    //
    // Every surface renders the same screen, so they must also agree about
    // whether that screen has been dismissed. Each one owning its own flag meant
    // Escape cleared the monitor it happened to be focused on and left the other
    // showing a fullscreen results page over the desktop. Half a dismissal is
    // not a dismissal.
    // The id must NOT match the property it is assigned to. `dismissal: dismissal`
    // inside the delegate resolves the right-hand side to the property being
    // declared, not to this object, so every surface silently received
    // `undefined` and every read of it threw at runtime. qmllint was clean and
    // the wiring greps all passed; only loading the shell found it.
    QtObject {
        id: sharedDismissal
        property bool done: false
    }

    // ESCAPE LEAVES. It does not merely hide a screen.
    //
    // Dismissing used to hide the surfaces and leave quickshell running with
    // nothing on screen, and the engine still loaded in the compositor. That is
    // not what "exit" means to anyone pressing Escape, and the process quietly
    // outlived every session.
    //
    // The callback path is explicit rather than guessed: whoever launched this
    // exports OMASHIFT_BIN, so the overlay never has to work out where the game
    // lives. Unset means someone ran quickshell by hand, and then leaving just
    // means quitting.
    //
    // Dismissal is the ONLY trigger, and dismissal only ever happens on an end
    // screen, so this cannot fire mid-stage. When the stale watch dismisses a
    // frozen game, calling --stop is exactly the right thing anyway.
    function leave() {
        const bin = Quickshell.env("OMASHIFT_BIN");
        if (bin && bin.length > 0) {
            Quickshell.execDetached([bin, "--stop"]);
        }
        Qt.quit();
    }

    /// Call back to the game by name. The overlay decides WHAT the player asked
    /// for; the launcher decides how to do it. That keeps every rule about
    /// stages, options and Lua on the far side of this boundary.
    function ask(mode) {
        const bin = Quickshell.env("OMASHIFT_BIN");
        if (bin && bin.length > 0) Quickshell.execDetached([bin, mode]);
    }

    /// Same, with an argument. Kept separate rather than variadic so a caller
    /// cannot accidentally pass a mode that needs one and forget it.
    function ask2(mode, arg) {
        const bin = Quickshell.env("OMASHIFT_BIN");
        if (bin && bin.length > 0) Quickshell.execDetached([bin, mode, arg]);
    }

    /// Save a picture of what is on screen.
    ///
    /// THE GAME HAS TO DO THIS, because it has taken the keyboard. A layer-shell
    /// surface with exclusive focus swallows every global shortcut including
    /// Hyprland's own, so the key a player would normally reach for does
    /// nothing on exactly the two screens this game was built to be
    /// screenshotted from.
    ///
    /// Deliberately NOT routed through `ask`: the launcher is about stages and
    /// options, and a screenshot is neither. It is a sibling command with its
    /// own name, found beside the launcher.
    function snapshot(label) {
        const bin = Quickshell.env("OMASHIFT_BIN");
        if (!bin || bin.length === 0) return;
        const dir = bin.substring(0, bin.lastIndexOf("/"));
        Quickshell.execDetached([dir + "/omashift-snapshot", label || "omashift"]);
    }

    Connections {
        target: sharedDismissal
        function onDoneChanged() {
            if (sharedDismissal.done) shellRoot.leave();
        }
    }

    Variants {
        model: Quickshell.screens

        Surface {
            required property var modelData
            screen: modelData
            state: engineState
            theme: quattro
            dismissal: sharedDismissal
            shell: shellRoot
            // EXACTLY ONE surface asks for the keyboard.
            //
            // Every monitor gets a surface, and each one was requesting
            // exclusive focus. Two surfaces demanding the same keyboard is a
            // fight the compositor has to settle, and the most likely reason
            // Escape did not always land on the first press. Which monitor owns
            // it does not matter: the keyboard is global, so Escape reaches the
            // owner wherever you are looking.
            focusOwner: modelData === Quickshell.screens[0]
        }
    }
}

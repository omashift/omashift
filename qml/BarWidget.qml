// Omashift on the Omarchy bar.
//
// THE ONE FILE HERE THAT SOMEBODY ELSE'S PROCESS LOADS. Everything else in
// qml/ is drawn by the game's own quickshell process, which stays standalone
// on purpose: a crash in a fullscreen game must not take the bar and the
// notifications down with it. See the header of shell.qml.
//
// So this is deliberately the smallest thing that can be useful. It draws a
// mark, reads one file, and spawns the launcher. It does not import a line of
// the game, and there is nothing in it that can fail in a way the shell would
// notice.
//
// ONE CLICK CANNOT TAKE YOUR KEYBOARD. `omashift` with no arguments arms a
// stage and draws the menu; the submap engages only when the player asks a
// second time, on a screen that says so. So the worst a stray click can do is
// put a menu on screen, with every one of your keybindings still live.
//
// A SECOND, DELIBERATE CLICK DOES START THE STAGE, exactly as pressing the
// launch chord twice does. That is the documented gate and it is not weakened
// here. What is guarded is the ACCIDENT: see the debounce on launch() below.
//
// AND THE LEFT CLICK IS ALSO THE WAY OUT. Before it does anything else, the
// launcher retires a submap that a previous stage left engaged. That matters
// more here than anywhere: a stranded submap answers SUPER + RETURN as a pace
// note, so there is no route to a terminal from the keyboard, and the pointer
// is the only way back in. This widget is that route.

// Quickshell.Io is deliberately absent. This widget performs no IO, and the
// import that would let it is the one worth not having.
import QtQuick
import qs.Ui
import qs.Commons

BarWidget {
    id: root

    // Must match manifest.json's id. The host looks the widget up by it, so a
    // drift here is a widget that loads and is then never addressed again.
    moduleName: "io.github.omashift.omashift"

    // The launcher, found relative to this file rather than on PATH.
    //
    // The plugin directory IS the checkout, so bin/omashift is always one level
    // up from here. Reaching for PATH instead would make the widget depend on
    // ./install having been run, and arriving through `omarchy plugin add` is
    // exactly the case where it has not been.
    readonly property string launcher:
        Qt.resolvedUrl("../bin/omashift").toString().replace(/^file:\/\//, "")

    // THIS WIDGET READS NOTHING. That is the point, and it cost a feature.
    //
    // It used to watch the engine's state document to tint the mark and word
    // the tooltip. The marketplace security review objected, and the second
    // pass named the part that actually matters: moving the file to a 0700
    // directory stops another USER, and stops nothing else. Every process
    // running as you, this shell's other plugins included, can still write it.
    //
    // No file check fixes that. A same user attacker's file is owned by you,
    // so an owner test passes; they can read any nonce we could sign with, and
    // ptrace the shell besides. The honest options were to bound the damage or
    // to stop taking the input, and this is the one file of ours that somebody
    // else's long-lived process loads. So it stops taking the input.
    //
    // WHAT THIS COSTS: the mark no longer lights while a stage is running, and
    // the tooltip no longer knows whether one is. WHAT IT DOES NOT COST: the
    // clicks, which never consulted the file. Both were always unconditional,
    // for a reason documented below that predates any of this.
    //
    // The game's own overlay still reads the document, in the game's own
    // process, where a hostile write costs a frame instead of the bar. See
    // StateReader.qml.

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    property double lastLaunchAt: 0

    /// Run the launcher, unless it was just run.
    ///
    /// A MOUSE DOUBLE CLICK IS NOT A SECOND ASK. The launch chord has an
    /// arm-then-fire gate, and pressing it twice is how a stage starts. A
    /// pointer produces that same second press by accident, all the time, and
    /// the accident is worse than it looks: the first launcher spends about
    /// two seconds staging the engine and waiting on the overlay before it
    /// writes the arm, so a click landing inside that window does not fire the
    /// stage at all. It starts a SECOND launcher, which loads the engine again
    /// underneath the first and restarts the overlay it is still waiting for.
    ///
    /// The window is therefore set to cover that staging, not to be a general
    /// dead time. A player who means to start a stage clicks again after the
    /// menu has appeared, which is on the far side of it.
    ///
    /// Argv rather than a command string: the path comes from wherever the
    /// plugin was installed, and a home directory with a space in it would
    /// otherwise arrive as two arguments.
    function launch(argv) {
        const now = Date.now();
        if (now - root.lastLaunchAt < 2500)
            return;
        root.lastLaunchAt = now;
        Util.execArgv(argv);
    }

    // WHAT THE CLICKS DO WAS NEVER READ OFF THE STATE FILE, which is why
    // dropping the read costs no behavior. The document outlives the game on
    // purpose: an end screen lingers until the next launch, so a present file
    // was never proof of a running stage. Deciding between "start" and "stop"
    // from it would have sent a click to the wrong action every time somebody
    // dismissed a results page.
    //
    // Both buttons are unconditional, and both are safe from every state: the
    // left click arms and repairs, the right click retires. That property is
    // what makes a widget with no state at all a complete one.

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar

        // Nothing lights it, because nothing here knows what the game is
        // doing any more. The alternative was to keep taking a document that
        // any process running as you can write, into the process that owns
        // the bar, for a tint.
        active: false

        // One wording for every state, and it has to be true in all of them.
        // Both halves always work: the left click opens the game or repairs a
        // stranded stage, the right click retires one.
        tooltipText: "Omashift. Left click to open it, right click to retire a stage."

        onPressed: function (buttonCode) {
            if (buttonCode === Qt.RightButton) {
                root.launch([root.launcher, "--stop"]);
            } else if (buttonCode === Qt.LeftButton) {
                root.launch([root.launcher]);
            }
        }

        // THE MARK IS THE H OF A GEARBOX GATE, the same letter the wordmark
        // builds from the 6 by 10 bitmap in assets/make-logo.py. Three
        // rectangles rather than that file's sixty cells, because at bar size
        // the groove and the lever are thinner than a pixel: only the H
        // survives the scale, so only the H is drawn.
        // EVERY REFERENCE IN HERE IS QUALIFIED BY AN id, and that is not a
        // style preference. A delegate reading a bare `cell` resolves it
        // through a scope chain rather than an object, and this project has
        // already lost a session to exactly that: shell.qml's shared dismissal
        // read as `undefined` at runtime with qmllint clean and every wiring
        // grep passing. Nothing offline loads QML, so an unqualified name here
        // would be found by a player and by nobody else.
        iconComponent: Component {
            Item {
                id: gate
                anchors.fill: parent

                // One grid cell. The glyph is 10 cells tall, which is what
                // makes it sit at the same optical weight as the nerd font
                // glyphs in the neighboring slots.
                readonly property real cell: Math.max(1, button.opticalSize / 10)
                readonly property color ink: button.active && button.useActiveColor
                    ? button.activeColor
                    : button.foreground

                Item {
                    anchors.centerIn: parent
                    width: gate.cell * 6
                    height: gate.cell * 10

                    Repeater {
                        // x, y, width, height, in grid cells.
                        model: [
                            [0, 0, 2, 10],
                            [4, 0, 2, 10],
                            [0, 4, 6, 2]
                        ]
                        Rectangle {
                            x: modelData[0] * gate.cell
                            y: modelData[1] * gate.cell
                            width: modelData[2] * gate.cell
                            height: modelData[3] * gate.cell
                            color: gate.ink
                        }
                    }
                }
            }
        }
    }
}

pragma Singleton
// One niri IPC tap, shared by every bar: the niri-state helper keeps the
// workspace/window model in memory and prints a snapshot line only when it
// changes, so a burst of niri events costs one socket read and one JSON.parse.
import QtQuick
import Quickshell
import Quickshell.Io
import qs

Singleton {
    id: root

    property var workspaces: []
    property var byOutput: ({})

    // The output a notification or a panel should appear on. It comes from the
    // snapshot rather than from `workspaces`, which holds only named ones -
    // focus sitting on a dynamic workspace would otherwise name no output.
    property string focusedOutput: ""

    function focusWorkspace(name: string): void {
        Quickshell.execDetached([Config.niri, "msg", "action", "focus-workspace", name]);
    }

    function focusColumn(idx: int): void {
        Quickshell.execDetached([Config.niri, "msg", "action", "focus-column", String(idx)]);
    }

    function toggleOverview(): void {
        Quickshell.execDetached([Config.niri, "msg", "action", "toggle-overview"]);
    }

    function strip(output: string): var {
        const o = root.byOutput[output];
        return o ? o.strip : null;
    }

    function title(output: string): string {
        const o = root.byOutput[output];
        return o ? o.title : "";
    }

    Process {
        id: tap
        command: [Config.niriState]
        running: true

        stdout: SplitParser {
            onRead: line => {
                const snapshot = JSON.parse(line);
                root.workspaces = snapshot.workspaces;
                root.byOutput = snapshot.by_output;
                root.focusedOutput = snapshot.focused_output;
            }
        }

        // niri going away (or a compositor restart) ends the tap; retry rather
        // than leave the left side of every bar frozen on its last snapshot.
        onExited: retry.restart()
    }

    Timer {
        id: retry
        interval: 2000
        onTriggered: tap.running = true
    }
}

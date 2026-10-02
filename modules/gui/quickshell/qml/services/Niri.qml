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
    property var strips: ({})
    property var titles: ({})

    // Serialised copies of the last assigned values. A snapshot is mostly a
    // title change (a terminal spinner sends ~12 a second), and reassigning an
    // unchanged array rebuilds every Repeater delegate built from it.
    property string _workspacesKey: ""
    property string _stripsKey: ""

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
        return root.strips[output] ?? null;
    }

    function title(output: string): string {
        return root.titles[output] ?? "";
    }

    Process {
        id: tap
        command: [Config.niriState]
        running: true

        stdout: SplitParser {
            onRead: line => {
                const snapshot = JSON.parse(line);
                const strips = {}, titles = {};
                for (const output in snapshot.by_output) {
                    strips[output] = snapshot.by_output[output].strip;
                    titles[output] = snapshot.by_output[output].title;
                }
                const workspacesKey = JSON.stringify(snapshot.workspaces);
                if (workspacesKey !== root._workspacesKey) {
                    root._workspacesKey = workspacesKey;
                    root.workspaces = snapshot.workspaces;
                }
                const stripsKey = JSON.stringify(strips);
                if (stripsKey !== root._stripsKey) {
                    root._stripsKey = stripsKey;
                    root.strips = strips;
                }
                root.titles = titles;
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

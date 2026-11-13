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

    // Named workspaces, without their strips: those change with every window
    // title, and the workspace cells must not be rebuilt for it.
    property var workspaces: []
    // Workspace name -> strip.
    property var strips: ({})
    property var titles: ({})
    // Window id -> title.
    property var windowTitles: ({})

    // Serialised copies of the last assigned values. A snapshot is mostly a
    // title change (a terminal spinner sends ~12 a second), and reassigning an
    // unchanged array rebuilds every Repeater delegate built from it.
    property string _workspacesKey: ""
    property string _stripsKey: ""

    // The output a notification or a panel should appear on. It comes from the
    // snapshot rather than from `workspaces`, which holds only named ones -
    // focus sitting on a dynamic workspace would otherwise name no output.
    property string focusedOutput: ""

    // As Mod+N: leaving an empty numbered workspace removes it.
    function focusWorkspace(name: string): void {
        Quickshell.execDetached([Config.niriWorkspaces, "focus", name]);
    }

    function focusColumn(idx: int): void {
        Quickshell.execDetached([Config.niri, "msg", "action", "focus-column", String(idx)]);
    }

    // Also brings its workspace and output into focus, which focus-column cannot.
    function focusWindow(id: int): void {
        Quickshell.execDetached([Config.niri, "msg", "action", "focus-window", "--id", String(id)]);
    }

    function toggleOverview(): void {
        Quickshell.execDetached([Config.niri, "msg", "action", "toggle-overview"]);
    }

    function strip(workspace: string): var {
        return root.strips[workspace] ?? null;
    }

    function title(output: string): string {
        return root.titles[output] ?? "";
    }

    // `cb` gets a base64 PNG of the window no larger than maxSize physical
    // pixels on a side, or "" on failure. `WindowPreview` is our own niri
    // request (pkgs/niri/window-preview.patch): niri's screenshot actions all
    // take the clipboard.
    function windowPreview(id: int, maxSize: int, cb: var): void {
        ipc.pending.push(cb);
        ipc.outbox.push(JSON.stringify({
            WindowPreview: {
                id: id,
                max_size: maxSize
            }
        }));
        if (ipc.connected)
            ipc.send();
        else
            ipc.connected = true;
    }

    // niri answers requests on one connection in order, so callbacks are a
    // queue.
    Socket {
        id: ipc

        property var pending: []
        property var outbox: []

        function send(): void {
            for (const line of outbox)
                write(line + "\n");
            outbox = [];
            flush();
        }

        function answer(b64: string): void {
            try {
                pending.shift()(b64);
            } catch (e) {
                // The asking item was destroyed while waiting.
            }
        }

        function fail(): void {
            outbox = [];
            while (pending.length > 0)
                answer("");
        }

        path: Quickshell.env("NIRI_SOCKET")
        onConnectedChanged: {
            if (connected)
                send();
            else
                fail();
        }
        onError: {
            connected = false;
            fail();
        }

        parser: SplitParser {
            onRead: line => {
                let b64 = "";
                try {
                    b64 = JSON.parse(line).Ok?.WindowPreview ?? "";
                } catch (e) {}
                ipc.answer(b64);
            }
        }
    }

    Process {
        id: tap
        command: [Config.niriState]
        running: true

        stdout: SplitParser {
            onRead: line => {
                const snapshot = JSON.parse(line);
                const strips = {};
                for (const ws of snapshot.workspaces) {
                    strips[ws.name] = ws.strip;
                    delete ws.strip;
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
                root.titles = snapshot.titles;
                root.windowTitles = snapshot.window_titles;
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

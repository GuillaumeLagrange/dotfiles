pragma Singleton
// The launcher panel's side of the `launcher` daemon (pkgs/launcher/AGENTS.md):
// one held socket, NDJSON both ways. The daemon matches and acts; this keeps
// what the panel draws - the open mode, the query, the rows and the cursor -
// and turns keys into requests.
import QtQuick
import Quickshell
import Quickshell.Io
import qs

Singleton {
    id: root

    // From `hello`: `{ mode, short, title, glyph }` per enabled mode.
    property var modes: []
    property bool open: false
    // The output the panel opened on, fixed while it is up.
    property string output: ""
    property string mode: "apps"
    property string query: ""
    // The last query sent, and the newest one whose results are shown.
    property int seq: 0
    property int shownSeq: 0
    property var items: []
    property int total: 0
    // `{ kind, text }` from the results, or null.
    property var status: null
    // The last `error` event, until the query or the mode changes.
    property string error: ""
    // What an activation that runs on says (`working`) until its `done` or `error`; the panel
    // takes no keys meanwhile, so it closes only once the work has ended (a copy landed).
    property string working: ""
    // The id of the row the cursor is on.
    property string cursor: ""
    // Whether the cursor was moved by hand since the query last changed. Until it is, it stays
    // on the first row, whatever the results bring; after, on its row while that is listed.
    property bool moved: false
    // Previews by id, kept while the panel is open.
    property var previews: ({})
    property bool pending: false
    readonly property bool busy: root.pending || root.shownSeq < root.seq
    readonly property bool connected: sock.connected
    readonly property int cursorIndex: root.items.findIndex(i => i.id === root.cursor)
    readonly property var current: root.cursorIndex >= 0 ? root.items[root.cursorIndex] : null
    readonly property var preview: root.current ? (root.previews[root.current.id] ?? null) : null
    readonly property var modeInfo: root.modes.find(m => m.mode === root.mode) ?? {
        mode: root.mode,
        short: "",
        title: root.mode.charAt(0).toUpperCase() + root.mode.slice(1),
        glyph: root.mode
    }

    readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") ?? "/tmp") + "/launcher.sock"
    property int backoff: 250

    function send(request: var): void {
        if (!sock.connected)
            return;
        sock.write(JSON.stringify(request) + "\n");
        sock.flush();
    }

    // Opens on the focused output in `mode`, or switches to it when already open.
    function show(mode: string): void {
        const target = mode !== "" ? mode : root.mode;
        if (!root.open) {
            root.output = Niri.focusedOutput;
            root.open = true;
        } else if (target === root.mode) {
            return;
        }
        root.switchMode(target);
    }

    function hide(): void {
        if (!root.open)
            return;
        root.open = false;
        root.send({
            op: "close"
        });
        root.reset();
    }

    function toggle(mode: string): void {
        if (root.open && (mode === "" || mode === root.mode))
            root.hide();
        else
            root.show(mode);
    }

    function reset(): void {
        root.query = "";
        root.items = [];
        root.total = 0;
        root.status = null;
        root.error = "";
        root.working = "";
        root.cursor = "";
        root.moved = false;
        root.previews = {};
        root.seq = 0;
        root.shownSeq = 0;
        root.pending = false;
    }

    function switchMode(mode: string): void {
        root.reset();
        root.mode = mode;
        root.pending = true;
        root.send({
            op: "open",
            mode
        });
    }

    // Tab and Shift+Tab: the next or previous mode of the hello.
    function cycle(step: int): void {
        const names = root.modes.map(m => m.mode);
        if (names.length === 0)
            return;
        const at = Math.max(0, names.indexOf(root.mode));
        root.switchMode(names[(at + step + names.length) % names.length]);
    }

    function setQuery(text: string): void {
        if (text === root.query)
            return;
        // `/name ` or `/short `: the mode, with the query starting over.
        const m = /^\/(\S+) $/.exec(text);
        const target = m ? root.modes.find(x => x.mode === m[1] || x.short === m[1]) : undefined;
        if (target) {
            root.switchMode(target.mode);
            return;
        }
        root.query = text;
        root.moved = false;
        root.error = "";
        root.seq++;
        root.send({
            op: "query",
            text,
            seq: root.seq
        });
    }

    // Runs `action` (an id) on `id`; empty: the item's default.
    function activate(id: string, action: string): void {
        if (root.working !== "")
            return;
        const request = {
            op: "activate",
            id
        };
        if (action !== "")
            request.action = action;
        root.send(request);
    }

    // Runs the current item's action bound to `key` ("Return", "Alt+Return"...).
    function activateKey(key: string): bool {
        const item = root.current;
        if (!item)
            return false;
        const action = (item.actions ?? []).find(a => a.key === key);
        if (action)
            root.activate(item.id, action.id);
        else if (key === "Return")
            root.activate(item.id, "");
        else
            return false;
        return true;
    }

    function step(delta: int): void {
        const n = root.items.length;
        if (n === 0)
            return;
        const at = root.cursorIndex < 0 ? (delta > 0 ? -1 : 0) : root.cursorIndex;
        root.cursor = root.items[((at + delta) % n + n) % n].id;
        root.moved = true;
    }

    // A row picked with the pointer.
    function select(id: string): void {
        root.cursor = id;
        root.moved = true;
    }

    function requestPreview(): void {
        const item = root.current;
        if (!root.open || !item || !item.preview || root.previews[item.id] !== undefined)
            return;
        root.send({
            op: "preview",
            id: item.id
        });
    }

    function receive(line: string): void {
        let ev;
        try {
            ev = JSON.parse(line);
        } catch (e) {
            console.warn("launcher: bad line", line);
            return;
        }
        switch (ev.type) {
        case "hello":
            root.modes = ev.modes ?? [];
            break;
        case "results":
            // Older than what is shown, or for a mode since left: stale.
            if (!root.open || ev.mode !== root.mode || ev.seq < root.shownSeq || ev.seq > root.seq)
                return;
            root.pending = false;
            root.shownSeq = ev.seq;
            root.items = ev.items ?? [];
            root.total = ev.total ?? root.items.length;
            root.status = ev.status ?? null;
            if (!root.moved || !root.items.some(i => i.id === root.cursor))
                root.cursor = root.items.length > 0 ? root.items[0].id : "";
            break;
        case "preview":
            {
                const previews = Object.assign({}, root.previews);
                previews[ev.id] = ev.preview ?? null;
                root.previews = previews;
                break;
            }
        case "working":
            root.working = ev.text ?? "";
            break;
        case "done":
            root.working = "";
            if (ev.close)
                root.hide();
            break;
        case "switch":
            root.working = "";
            if (root.open)
                root.switchMode(ev.mode);
            break;
        case "error":
            root.pending = false;
            root.working = "";
            root.error = ev.message ?? "error";
            break;
        }
    }

    // The daemon restarted, or came up after the bar: start over with `open`.
    function connectedAgain(): void {
        root.backoff = 250;
        if (!root.open)
            return;
        const query = root.query;
        root.switchMode(root.mode);
        if (query !== "")
            root.setQuery(query);
    }

    Socket {
        id: sock

        path: root.socketPath
        connected: true
        onConnectedChanged: if (sock.connected)
            root.connectedAgain()

        parser: SplitParser {
            onRead: line => root.receive(line)
        }
    }

    // Quickshell only connects when asked: a dropped or refused connection
    // stays down, so ask again, backing off, until the daemon answers.
    Timer {
        interval: root.backoff
        repeat: true
        running: !sock.connected
        onTriggered: {
            root.backoff = Math.min(root.backoff * 2, 4000);
            sock.connected = false;
            sock.connected = true;
        }
    }
}

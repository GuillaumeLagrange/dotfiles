pragma Singleton
// Pull requests awaiting my review, those I reviewed lately and my own open
// ones, with their stacks, as `reviews --json` lays them out. It reads the
// picker's cache, which the reviews-refresh user timer rewrites every 5
// minutes, and `refresh()` rewrites now.
import QtQuick
import Quickshell
import Quickshell.Io
import qs

Singleton {
    id: root

    // One per tab of the picker, each `{ count, stale, rows, all }`: `kind`
    // "stack" heads the PRs after it (`place` "child" / "last"); "alone" PRs
    // are in no stack. `rows` leaves out what `all` adds: stale PRs.
    readonly property var empty: ({ count: 0, stale: 0, rows: [], all: [] })
    property var requested: empty
    property var reviewed: empty
    property var mine: empty
    // PRs awaiting my review, what the pill counts.
    readonly property int count: requested.count
    // The panel's tab, kept across opens: "requested", "reviewed" or "mine".
    property string tab: "requested"
    // Stale PRs (no update in 60 days) are listed too; kept across opens.
    property bool showStale: false
    property real fetchedAt: 0
    readonly property bool refreshing: refresher.running
    // The last refresh's failure, cleared by the next one.
    property string error: ""

    // Set when asked again mid-read, so a change landing during it is not lost.
    property bool _stale: false
    property string _snapshot: ""

    function reload() {
        if (feed.running)
            _stale = true;
        else
            feed.running = true;
    }

    function refresh() {
        if (refresher.running)
            return;
        error = "";
        refresher.running = true;
    }

    Process {
        id: feed

        command: [Config.reviews, "--json"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const f = JSON.parse(this.text);
                    root._snapshot = f.snapshot;
                    root.requested = f.requested;
                    root.reviewed = f.reviewed;
                    root.mine = f.mine;
                    root.fetchedAt = f.fetched_at ?? 0;
                } catch (e) {
                    // Keep the last good state.
                }
            }
        }
        onExited: if (root._stale) {
            root._stale = false;
            running = true;
        }
    }

    Process {
        id: refresher

        command: [Config.reviews, "--refresh"]
        stdout: StdioCollector {}
        stderr: StdioCollector {
            id: refreshErr
        }
        onExited: code => {
            if (code !== 0)
                root.error = refreshErr.text.trim().split("\n").pop().trim() || `refresh exited ${code}`;
            root.reload();
        }
    }

    // The timer's refreshes; the path is the one the CLI reported.
    FileView {
        path: root._snapshot
        watchChanges: true
        preload: false
        printErrors: false
        onFileChanged: root.reload()
    }
}

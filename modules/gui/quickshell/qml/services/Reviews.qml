pragma Singleton
// Pull requests awaiting my review, with their stacks, as `reviews --json` lays
// them out. It reads the picker's cache, which the reviews-refresh user timer
// rewrites every 5 minutes, and `refresh()` rewrites now.
import QtQuick
import Quickshell
import Quickshell.Io
import qs

Singleton {
    id: root

    // `kind` "stack" heads the PRs after it (`place` "child" / "last");
    // "alone" PRs are in no stack.
    property var rows: []
    property int count: 0
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
                    root.rows = f.rows;
                    root.count = f.count;
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

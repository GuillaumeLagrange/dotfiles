pragma Singleton
// Claude Code usage badge. Config.claudeUsage wraps `omp usage` and owns the
// fetching and caching; this reruns it every 5 minutes.
import QtQuick
import Quickshell
import Quickshell.Io
import qs

Singleton {
    id: root

    property string text: `${Config.glyph.claude} --`
    property string tooltip: ""
    property string cls: "low"

    function refresh(arg: string): void {
        invalidate.command = [Config.claudeUsage, arg];
        invalidate.running = true;
    }

    function _apply(json: string): void {
        try {
            const data = JSON.parse(json);
            root.text = data.text;
            root.tooltip = data.tooltip ?? "";
            root.cls = data.class;
        } catch (e) {
            // Malformed output from a transient failure: keep the last good state.
        }
    }

    Process {
        id: fetch
        command: [Config.claudeUsage]
        running: true
        stdout: StdioCollector {
            onStreamFinished: root._apply(this.text)
        }
    }

    // Cache-invalidation call; its own output is discarded and `fetch` reruns
    // to pick up the fresh value.
    Process {
        id: invalidate
        stdout: StdioCollector {}
        onExited: fetch.running = true
    }

    Timer {
        interval: 300000
        running: true
        repeat: true
        onTriggered: fetch.running = true
    }
}

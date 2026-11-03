// Spliced into the test copy's ReviewsPill: `qs ipc call test state` prints
// the pill's place on the output and the reviews panel's state as JSON.
import QtQuick
import Quickshell
import Quickshell.Io

// Not the IpcHandler itself: it would try to expose these over IPC.
Item {
    id: probe

    required property Item pill
    required property var panel

    IpcHandler {
        target: "test"

        function state(): string {
            const pill = probe.pill;
            const panel = probe.panel;
            const win = pill.QsWindow.window;
            const at = pill.mapToItem(null, 0, 0, pill.width, pill.height);
            return JSON.stringify({
                hovered: pill.hovered,
                open: panel.visible,
                tab: panel.tab,
                query: panel.probeQuery,
                cursor: panel.cursor,
                matching: panel.matching.map(r => r.kind === "stack" ? "stack" : r.number),
                pill: {
                    // The bar window is anchored to the bottom of the output.
                    x: at.x,
                    y: win.screen.height - win.height + at.y,
                    w: at.width,
                    h: at.height
                }
            });
        }
    }
}

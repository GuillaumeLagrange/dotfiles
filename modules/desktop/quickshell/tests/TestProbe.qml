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

    // The panel's Linear issue buttons on screen, by identifier.
    function chips(item: Item, win: var, out: var): var {
        for (const child of item.children) {
            if (child.modelData?.identifier !== undefined && typeof child.selected === "boolean" && child.visible) {
                const at = child.mapToItem(null, 0, 0, child.width, child.height);
                out[child.modelData.identifier] = {
                    x: at.x,
                    y: win.screen.height - win.height + at.y,
                    w: at.width,
                    h: at.height
                };
            }
            probe.chips(child, win, out);
        }
        return out;
    }

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
                issueCursor: panel.issueCursor,
                chips: panel.visible ? probe.chips(panel.contentItem, panel, {}) : {},
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

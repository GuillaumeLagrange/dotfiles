// Spliced into the test copy's Workspaces: `qs ipc call workspaces cells`
// prints each cell's name, state and place on the output, and its strip's
// place (null while hidden), as JSON.
import QtQuick
import Quickshell
import Quickshell.Io

// Invisible, so the Row it sits in lays it out as nothing.
Item {
    id: probe

    required property Item row

    visible: false

    IpcHandler {
        target: "workspaces"

        function cells(): string {
            const win = probe.row.QsWindow.window;
            return JSON.stringify(probe.row.children.filter(c => c.modelData !== undefined).map(c => {
                const place = item => {
                    const at = item.mapToItem(null, 0, 0, item.width, item.height);
                    // The bar window is anchored to the bottom of the output.
                    return {
                        x: at.x,
                        y: win.screen.height - win.height + at.y,
                        w: at.width,
                        h: at.height
                    };
                };
                return Object.assign({
                    name: c.modelData.name,
                    focused: c.modelData.is_focused,
                    strip: c.strip.visible ? place(c.strip) : null
                }, place(c.cell));
            }));
        }
    }
}

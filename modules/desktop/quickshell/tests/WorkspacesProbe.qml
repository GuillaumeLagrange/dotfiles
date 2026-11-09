// Spliced into the test copy's Workspaces: `qs ipc call workspaces cells`
// prints each cell's name, state and place on the output as JSON.
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
                const at = c.mapToItem(null, 0, 0, c.width, c.height);
                return {
                    name: c.modelData.name,
                    focused: c.modelData.is_focused,
                    // The bar window is anchored to the bottom of the output.
                    x: at.x,
                    y: win.screen.height - win.height + at.y,
                    w: at.width,
                    h: at.height
                };
            }));
        }
    }
}

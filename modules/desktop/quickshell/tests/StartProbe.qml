// Spliced into the test copy's StartCorner: `qs ipc call start state` prints
// the start menu's state as JSON, with the tiles' and rows' places on the output.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// Not the IpcHandler itself: it would try to expose these over IPC.
Item {
    id: probe

    required property var menu

    function place(item: Item): var {
        const at = item.mapToItem(null, 0, 0, item.width, item.height);
        return {
            x: at.x + at.width / 2,
            y: at.y + at.height / 2
        };
    }

    IpcHandler {
        target: "start"

        function state(): string {
            const menu = probe.menu;
            const list = menu.probeList;
            const rows = [];
            for (let i = 0; i < list.count; i++) {
                const row = list.itemAtIndex(i);
                if (row)
                    rows.push(Object.assign({
                        name: row.modelData.name
                    }, probe.place(row)));
            }
            const tiles = menu.probeGrid.children.filter(c => c.modelData !== undefined).sort((a, b) => a.slot - b.slot).map(t => Object.assign({
                    name: t.modelData.name
                }, probe.place(t)));
            return JSON.stringify({
                open: menu.visible,
                query: menu.probeQuery,
                cursor: menu.cursor,
                pins: StartPins.ids,
                tiles: tiles,
                rows: rows
            });
        }
    }
}

// Spliced into the test copy's popups/Launcher.qml, whose `launcher` IpcHandler
// gains `state()`: `qs ipc call launcher state` prints the panel as JSON.
import QtQuick

QtObject {
    id: probe

    required property var panel

    function json(): string {
        const panel = probe.panel;
        const svc = panel.svc;
        // None while the panel is closed.
        const list = panel.probeList;
        const rows = [];
        for (let i = 0; list && i < list.count; i++) {
            const row = list.itemAtIndex(i);
            if (row)
                rows.push({
                    id: row.modelData.id,
                    title: row.modelData.title
                });
        }
        // What the list shows: the index of its top row, and whether the cursor's row is
        // wholly inside the viewport.
        const top = list ? list.indexAt(1, list.contentY + 1) : -1;
        const at = list ? list.itemAtIndex(svc.cursorIndex) : null;
        const cursorVisible = at !== null && at.y >= list.contentY - 0.5 && at.y + at.height <= list.contentY + list.height + 0.5;
        return JSON.stringify({
            open: panel.visible,
            // Keys reach the panel: niri gives a layer surface focus a moment after it maps.
            focused: panel.focused,
            connected: svc.connected,
            mode: svc.mode,
            modes: svc.modes.map(m => m.mode),
            query: svc.query,
            cursor: svc.cursor,
            rows: rows,
            top: top,
            cursorVisible: cursorVisible,
            status: svc.status,
            error: svc.error,
            // What the footer says: the error, the work an activation waits for, or the status.
            statusLine: panel.probeStatusLine,
            // The loading bar under the search row, shown once an answer is late.
            loading: panel.probeLoading,
            preview: svc.preview ? svc.preview.kind : null,
            menu: panel.menuOpen,
            menuActions: panel.menuActions.map(a => a.id)
        });
    }
}

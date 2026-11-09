pragma Singleton
// The tray's order: the drawer's icons and the ones pinned out of it, by SNI
// id, which an app keeps across restarts (the bus name does not). Icons never
// placed sit at the end of the drawer.
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property var drawer: []
    property var pins: []

    function save(drawer: var, pins: var): void {
        root.drawer = drawer;
        root.pins = pins;
        orderFile.setText(JSON.stringify({
            drawer: drawer,
            pins: pins
        }, null, 2) + "\n");
    }

    FileView {
        id: orderFile

        path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/quickshell/tray-order.json"
        printErrors: false
        onLoaded: {
            try {
                const order = JSON.parse(orderFile.text());
                if (Array.isArray(order.drawer) && Array.isArray(order.pins)) {
                    root.drawer = order.drawer;
                    root.pins = order.pins;
                }
            } catch (e) {
                // Keep the last good state.
            }
        }
    }
}

pragma Singleton
// The start menu's pinned apps, by desktop entry id, in the order they are
// shown. Kept out of the Nix config: pinning is done from the menu.
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property var ids: []

    function pinned(id: string): bool {
        return root.ids.includes(id);
    }

    function toggle(id: string): void {
        root.save(root.pinned(id) ? root.ids.filter(i => i !== id) : root.ids.concat([id]));
    }

    function save(ids: var): void {
        root.ids = ids;
        pinsFile.setText(JSON.stringify(ids, null, 2) + "\n");
    }

    FileView {
        id: pinsFile

        path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/quickshell/start-pins.json"
        printErrors: false
        onLoaded: {
            try {
                const ids = JSON.parse(pinsFile.text());
                if (Array.isArray(ids))
                    root.ids = ids.filter(id => typeof id === "string");
            } catch (e) {
                // Keep the last good state.
            }
        }
    }
}

pragma Singleton
// Each zellij session's colour (pkgs/zellij-sessions), for marking the windows
// that show it. Set from omp-panel; read here from its files.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

Singleton {
    id: root

    // Session name -> "#rrggbb".
    property var colors: ({})
    property var _palette: ({})
    property var _sessions: []

    function _rebuild(): void {
        const colors = {};
        for (const entry of root._sessions) {
            const hex = root._palette[entry.color];
            if (hex)
                colors[entry.name] = hex;
        }
        root.colors = colors;
    }

    // The colour of the session a window shows, from the title zellij gives its
    // terminal (`<session> | <pane>`), or "".
    function windowColor(id: var): string {
        const title = Niri.windowTitles[id] ?? "";
        const cut = title.indexOf(" | ");
        return root.colors[cut < 0 ? title : title.slice(0, cut)] ?? "";
    }

    FileView {
        id: paletteFile

        path: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/zellij-sessions/palette.json"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const palette = {};
                for (const swatch of JSON.parse(paletteFile.text()))
                    palette[swatch.name] = swatch.color;
                root._palette = palette;
                root._rebuild();
            } catch (e) {}
        }
    }

    FileView {
        id: sessionsFile

        path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/zellij-sessions/sessions.json"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                root._sessions = JSON.parse(sessionsFile.text()).sessions ?? [];
                root._rebuild();
            } catch (e) {}
        }
    }
}

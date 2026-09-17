pragma Singleton
// Presentation mapping shared by the bar pill and the now-playing panel, so
// both agree on which player is active and how it looks.
import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import qs

Singleton {
    id: root

    // playerctld proxies whichever player is active, so listing it alongside
    // them shows the same track twice.
    readonly property var players: Mpris.players.values.filter(p => !(p.dbusName || "").endsWith(".playerctld"))

    // A playing player, else the first one present.
    readonly property var active: {
        const list = root.players;
        for (let i = 0; i < list.length; i++) {
            if (list[i].isPlaying)
                return list[i];
        }
        return list.length > 0 ? list[0] : null;
    }

    function key(player) {
        const name = ((player.desktopEntry || "") + " " + (player.identity || "")).toLowerCase();
        if (name.includes("spotify"))
            return "spotify";
        if (name.includes("firefox"))
            return "firefox";
        if (name.includes("chromium") || name.includes("chrome"))
            return "chrome";
        if (name.includes("mpv") || name.includes("vlc"))
            return "movie";
        return "music";
    }

    function iconFor(player) {
        return Config.glyph[root.key(player)];
    }

    function colorFor(player) {
        switch (root.key(player)) {
        case "spotify":
            return Theme.green;
        case "firefox":
            return Theme.orange;
        case "chrome":
            return Theme.blue;
        default:
            return Theme.aqua;
        }
    }

    function format(seconds) {
        const s = Math.max(0, Math.floor(seconds));
        const m = Math.floor(s / 60);
        const r = s % 60;
        return `${m}:${r < 10 ? "0" : ""}${r}`;
    }
}

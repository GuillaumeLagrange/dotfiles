pragma Singleton
// Presentation mapping shared by the bar pill and the now-playing panel, so
// both agree on which player is active and how it looks. Ports mpris.py's
// icon()/color()/pick_active()/fmt_time() — the D-Bus plumbing itself is gone,
// replaced by Quickshell.Services.Mpris.
import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import qs

Singleton {
    id: root

    // playerctld proxies whichever player is active, so listing it alongside
    // them shows the same track twice (mpris.py filtered it out the same way).
    readonly property var players: Mpris.players.values.filter(p => !(p.dbusName || "").endsWith(".playerctld"))

    // mpris.py picked whatever playerctld was forwarding (i.e. what your media
    // keys hit), falling back to a Playing player, then the first present.
    // Quickshell has no playerctld tap, so every player takes that fallback.
    readonly property var active: {
        const list = root.players;
        for (let i = 0; i < list.length; i++) {
            if (list[i].isPlaying)
                return list[i];
        }
        return list.length > 0 ? list[0] : null;
    }

    // mpris.py matched on the D-Bus bus name suffix; Quickshell doesn't expose
    // that split, so the same prefixes are matched against desktopEntry/identity.
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

    // mpris.py's color() only special-cases spotify/firefox/chromium; mpv, vlc
    // and everything else default to aqua, same as the movie/music icons here.
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

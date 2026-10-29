pragma Singleton
// Pull requests awaiting my review, read from the reviews picker's cache, which
// the reviews-refresh user timer rewrites every 5 minutes.
import QtQuick
import Quickshell
import Quickshell.Io
import qs

Singleton {
    id: root

    property var prs: []
    property real fetchedAt: 0
    readonly property int count: prs.length
    readonly property string dir: (Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache") + "/reviews"

    FileView {
        id: cache

        path: root.dir + "/prs.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                const snapshot = JSON.parse(cache.text());
                // Unlisted entries are stack members pulled in for context.
                root.prs = snapshot.lists.requested.filter(pr => pr.listed);
                root.fetchedAt = snapshot.fetched_at;
            } catch (e) {
                // Keep the last good state.
            }
        }
    }
}

pragma Singleton
// The session's notification daemon. NotificationServer takes the
// org.freedesktop.Notifications bus name, which is why mako no longer runs -
// only one process can own it.
//
// Two lists, because they have different lifetimes: the popup stack is the
// server's tracked notifications, which the sending application can close out
// from under us, and the centre holds snapshots taken on arrival, which
// survive that.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications

Singleton {
    id: root

    // Was mako's `app-name=Slack { invisible=1 }`: no popup, still in the centre.
    readonly property var silentApps: ["Slack"]
    // mako's default-timeout, for clients that send -1 (server decides).
    readonly property int defaultTimeout: 10000
    readonly property int historyLimit: 100

    property bool dnd: false
    readonly property var popups: server.trackedNotifications.values
    property var history: []
    property int unread: 0

    // Mod+N reaches every bar; the one on the focused output answers.
    signal centerToggleRequested

    function toggleDnd(): void {
        root.dnd = !root.dnd;
    }

    function dismissAll(): void {
        for (const notification of Array.from(root.popups))
            notification.dismiss();
    }

    function forget(key: int): void {
        root.history = root.history.filter(entry => entry.key !== key);
    }

    function clearHistory(): void {
        root.history = [];
        root.unread = 0;
    }

    function markRead(): void {
        root.unread = 0;
    }

    // The notification's own image first, then the sending application's icon,
    // which is a freedesktop icon name unless the client sent a path.
    function iconFor(image: string, appIcon: string): string {
        if (image !== "")
            return image;
        if (appIcon === "")
            return "";
        if (appIcon.startsWith("/") || appIcon.startsWith("file:"))
            return appIcon;
        return Quickshell.iconPath(appIcon, true);
    }

    function isCritical(notification): bool {
        return notification.urgency === NotificationUrgency.Critical;
    }

    function ago(time: real): string {
        const minutes = Math.floor((Date.now() - time) / 60000);
        if (minutes < 1)
            return "now";
        if (minutes < 60)
            return minutes + "m";
        if (minutes < 1440)
            return Math.floor(minutes / 60) + "h";
        return Qt.formatDateTime(new Date(time), "MMM d");
    }

    property int nextKey: 1

    NotificationServer {
        id: server

        actionsSupported: true
        actionIconsSupported: true
        bodyMarkupSupported: true
        bodyImagesSupported: true
        imageSupported: true
        persistenceSupported: true
        keepOnReload: true

        onNotification: notification => {
            root.history = [
                {
                    key: root.nextKey++,
                    appName: notification.appName,
                    summary: notification.summary,
                    body: notification.body,
                    image: notification.image,
                    appIcon: notification.appIcon,
                    critical: notification.urgency === NotificationUrgency.Critical,
                    time: Date.now()
                },
                ...root.history
            ].slice(0, root.historyLimit);
            root.unread++;

            // Not tracking is how a notification is discarded: no popup, and the
            // client is told nothing, which is what mako's `invisible` did.
            notification.tracked = !root.dnd && !root.silentApps.includes(notification.appName);
        }
    }

    IpcHandler {
        target: "notifs"

        function center(): void {
            root.centerToggleRequested();
        }

        function dismiss(): void {
            root.dismissAll();
        }

        function dnd(): void {
            root.toggleDnd();
        }
    }
}

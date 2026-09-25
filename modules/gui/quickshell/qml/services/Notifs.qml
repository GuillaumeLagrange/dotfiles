pragma Singleton
// The session's notification daemon. NotificationServer takes the
// org.freedesktop.Notifications bus name, which is why mako no longer runs -
// only one process can own it.
//
// Two lists, because they have different lifetimes: the popup stack is a set of
// ids the bar is currently drawing, and the centre holds snapshots taken on
// arrival, which outlive the objects the server destroys.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications

Singleton {
    id: root

    // Was mako's `app-name=Slack { invisible=1 }`: no popup, still in the centre.
    readonly property var silentApps: ["Slack"]
    // Dropped on arrival, popup and centre alike: niri confirms every
    // screenshot, right after its own UI showed what was captured.
    readonly property var ignoredNotifs: [
        {
            appName: "niri",
            summary: "Screenshot captured"
        }
    ]
    // mako's default-timeout, for clients that send -1 (server decides).
    readonly property int defaultTimeout: 10000
    readonly property int historyLimit: 100

    property bool dnd: false
    // Snapshots, newest first. `read` is per row: a notification interacted
    // with is not something to catch up on.
    property var history: []
    readonly property int unread: root.history.reduce((count, entry) => count + (entry.read ? 0 : 1), 0)

    readonly property var liveNotifs: Array.from(server.trackedNotifications.values)
    // Ids on the popup stack. A popup is a view of a live notification, not its
    // lifetime: a timeout drops the id and leaves the notification open.
    property var popupIds: []
    readonly property var popups: root.liveNotifs.filter(notification => root.popupIds.includes(notification.id))

    // Mod+N reaches every bar; the one on the focused output answers.
    signal centerToggleRequested

    function toggleDnd(): void {
        root.dnd = !root.dnd;
    }

    function liveFor(notifId: int): var {
        return root.liveNotifs.find(notification => notification.id === notifId) ?? null;
    }

    // The centre's action buttons: a row has them only while the notification
    // behind it is still held open.
    function actionsFor(notifId: int): var {
        const notification = root.liveFor(notifId);
        return notification ? notification.actions : [];
    }

    // Popup gestures. Each one is an interaction, so the row stops counting as
    // unread - unlike a timeout, which nobody looked at.
    function activate(notification): void {
        root.markRead(notification.id);
        const fallback = notification.actions.find(action => action.identifier === "default");
        if (fallback)
            root.invokeAction(notification, fallback);
        else
            root.dismiss(notification);
    }

    function invokeAction(notification, action): void {
        root.markRead(notification.id);
        root.popupIds = root.popupIds.filter(id => id !== notification.id);
        // Closes the notification unless the sender asked to stay resident.
        action.invoke();
        root.sweep();
    }

    function dismiss(notification): void {
        root.markRead(notification.id);
        root.release(notification);
    }

    function expire(notification): void {
        root.release(notification);
    }

    // Clears the screen. What it leaves behind is a centre row, still carrying
    // whatever the notification offers.
    function dismissAll(): void {
        for (const notification of root.popups)
            root.release(notification);
    }

    // Takes a notification off the popup stack. It stays open while a centre row
    // points at it, which is what keeps the row's buttons live and leaves the
    // sender something to withdraw.
    function release(notification): void {
        root.popupIds = root.popupIds.filter(id => id !== notification.id);
        root.sweep();
    }

    // The sender closed its own notification: it was dealt with somewhere else,
    // so the row goes rather than sitting there as a dead snapshot.
    function withdraw(notifId: int): void {
        root.popupIds = root.popupIds.filter(id => id !== notifId);
        root.history = root.history.filter(entry => entry.notifId !== notifId);
        // Deferred: the server is mid-removal, and a sweep here still sees the
        // closing notification in its model.
        Qt.callLater(root.sweep);
    }

    // Centre rows are snapshots, so they act through the notification behind
    // them - when one is still held - and the row goes either way.
    function activateEntry(entry): void {
        const notification = root.liveFor(entry.notifId);
        if (notification)
            root.activate(notification);
        root.forget(entry.key);
    }

    function invokeEntryAction(entry, action): void {
        action.invoke();
        root.forget(entry.key);
    }

    function forget(key: int): void {
        root.history = root.history.filter(entry => entry.key !== key);
        root.sweep();
    }

    // Empties the screen and the centre. With both lists empty, the sweep finds
    // nothing pointing at a held notification and closes them all.
    function clearAll(): void {
        root.popupIds = [];
        root.history = [];
        root.sweep();
    }

    function markRead(notifId: int): void {
        root.history = root.history.map(entry => entry.notifId === notifId && !entry.read ? Object.assign({}, entry, {
            read: true
        }) : entry);
    }

    function markAllRead(): void {
        root.history = root.history.map(entry => entry.read ? entry : Object.assign({}, entry, {
            read: true
        }));
    }

    // Keeps a notification open while a popup or a centre row points at it, and
    // closes it once nothing does. While open, its actions stay callable and its
    // sender can still withdraw it. historyLimit bounds how many are held.
    function sweep(): void {
        const live = root.liveNotifs;
        root.popupIds = root.popupIds.filter(id => live.some(notification => notification.id === id));

        for (const notification of live)
            if (!root.popupIds.includes(notification.id) && !root.history.some(entry => entry.notifId === notification.id))
                notification.expire();
    }

    function isIgnored(notification): bool {
        return root.ignoredNotifs.some(rule => rule.appName === notification.appName && rule.summary === notification.summary);
    }

    // Both a new notification and a client reusing an id land here.
    function arrive(notification): void {
        if (root.isIgnored(notification)) {
            // Never tracked: the server drops it and tells the sender so.
            notification.tracked = false;
            return;
        }

        const popup = !root.dnd && !root.silentApps.includes(notification.appName);
        // Held while its row lives, whether it popped up or not: that is what
        // keeps an action callable and a withdrawal observable.
        notification.tracked = true;

        if (popup && !root.popupIds.includes(notification.id))
            root.popupIds = [...root.popupIds, notification.id];

        root.history = [
            {
                key: root.nextKey++,
                notifId: notification.id,
                appName: notification.appName,
                summary: notification.summary,
                body: notification.body,
                image: notification.image,
                appIcon: notification.appIcon,
                critical: notification.urgency === NotificationUrgency.Critical,
                read: false,
                time: Date.now()
            },
            // A replaced notification keeps one row, at the top.
            ...root.history.filter(entry => entry.notifId !== notification.id)
        ].slice(0, root.historyLimit);

        // Deferred: the server only inserts the notification into its model
        // once this handler returns, and a sweep that cannot see it there
        // takes it for an id with nothing behind it.
        Qt.callLater(root.sweep);
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

        onNotification: notification => root.arrive(notification)
    }

    // Everything a live notification says about itself, since onNotification
    // only fires for ones the server has not seen: a client reusing an id
    // updates the object in place, and a client closing one is only heard here.
    Instantiator {
        model: server.trackedNotifications

        delegate: QtObject {
            id: watcher

            required property var modelData
            // Read up front: the close handler runs while the server is taking
            // the object apart.
            readonly property int notifId: watcher.modelData.id

            readonly property Connections tracker: Connections {
                target: watcher.modelData

                function onSummaryChanged(): void {
                    root.arrive(watcher.modelData);
                }

                function onBodyChanged(): void {
                    root.arrive(watcher.modelData);
                }

                // Only the sender's own close says something this shell does not
                // already know: every other reason is a close it just asked for.
                function onClosed(reason): void {
                    if (reason === NotificationCloseReason.CloseRequested)
                        root.withdraw(watcher.notifId);
                }
            }
        }
    }

    IpcHandler {
        target: "notifs"

        function center(): void {
            root.centerToggleRequested();
        }

        function clear(): void {
            root.clearAll();
        }

        function dnd(): void {
            root.toggleDnd();
        }
    }
}

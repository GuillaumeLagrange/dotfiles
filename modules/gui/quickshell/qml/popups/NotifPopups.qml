// The popup stack: one layer surface per output, in the top-right corner,
// showing the notifications the server is tracking.
//
// Top layer, never Overlay: hyprlock is an overlay surface, and a popup drawn
// over the lock screen would read out message bodies to anyone walking past.
// mako's default `top` layer is what hides them today.
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs
import qs.components
import qs.services

PanelWindow {
    id: root

    required property var modelData

    readonly property int cardWidth: 380
    readonly property int pad: 8
    // Newest first, nearest the corner, and only the tail of a burst is on screen.
    readonly property var shown: Notifs.popups.slice(-5).reverse()

    screen: modelData
    // Notifications follow the focus, the way mako's default output does.
    visible: root.shown.length > 0 && modelData.name === Niri.focusedOutput
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "quickshell-notifications"

    // Sized from the content: a layer surface that maps at 0x0 never gets
    // pointer input, even after it resizes.
    implicitWidth: root.cardWidth + root.pad * 2
    implicitHeight: stack.implicitHeight + root.pad * 2

    anchors {
        top: true
        right: true
    }

    Column {
        id: stack

        anchors.fill: parent
        anchors.margins: root.pad
        spacing: 8

        Repeater {
            model: root.shown

            Item {
                id: entry

                required property var modelData

                // -1 asks for the server default, 0 means it never expires.
                // The value is milliseconds, whatever quickshell's docs say.
                readonly property int timeout: {
                    const requested = entry.modelData.expireTimeout;
                    if (requested === 0)
                        return 0;
                    return requested > 0 ? requested : Notifs.defaultTimeout;
                }

                width: stack.width
                implicitHeight: card.implicitHeight
                height: card.implicitHeight

                NotifCard {
                    id: card

                    width: parent.width
                    surface: Theme.drawerBg
                    appName: entry.modelData.appName
                    summary: entry.modelData.summary
                    body: entry.modelData.body
                    iconSource: Notifs.iconFor(entry.modelData.image, entry.modelData.appIcon)
                    critical: Notifs.isCritical(entry.modelData)
                    actions: entry.modelData.actions

                    onActivated: Notifs.activate(entry.modelData)
                    onDismissed: Notifs.dismiss(entry.modelData)
                    onActionInvoked: action => Notifs.invokeAction(entry.modelData, action)
                }

                // Paused while the pointer is on the card, so a notification
                // being read does not vanish mid-sentence. Expiry only takes
                // the popup down: what it leaves is the service's to decide.
                Timer {
                    running: entry.timeout > 0 && !cardHover.hovered
                    interval: entry.timeout
                    onTriggered: Notifs.expire(entry.modelData)
                }

                HoverHandler {
                    id: cardHover
                }
            }
        }
    }
}

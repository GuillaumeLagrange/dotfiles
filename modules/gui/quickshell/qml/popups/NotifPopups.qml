// The popup stack: one layer surface per output, above the bar, showing the
// notifications the server is tracking.
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
    // Newest last, nearest the bar, and only the tail of a burst is on screen.
    readonly property var shown: Notifs.popups.slice(-5)

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
        bottom: true
        right: true
    }

    margins.bottom: Theme.windowHeight

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
                readonly property int timeout: {
                    const requested = entry.modelData.expireTimeout;
                    if (requested === 0)
                        return 0;
                    return requested > 0 ? requested * 1000 : Notifs.defaultTimeout;
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

                    // A click with no default action is just a dismissal, which
                    // is what a notification with nothing to open deserves.
                    onActivated: {
                        const fallback = entry.modelData.actions.find(action => action.identifier === "default");
                        if (fallback)
                            fallback.invoke();
                        else
                            entry.modelData.dismiss();
                    }

                    onDismissed: entry.modelData.dismiss()
                    onActionInvoked: action => action.invoke()
                }

                // Paused while the pointer is on the card, so a notification
                // being read does not vanish mid-sentence.
                Timer {
                    running: entry.timeout > 0 && !cardHover.hovered
                    interval: entry.timeout
                    onTriggered: entry.modelData.expire()
                }

                HoverHandler {
                    id: cardHover
                }
            }
        }
    }
}

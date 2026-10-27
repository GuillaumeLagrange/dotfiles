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
    readonly property var shown: Notifs.shown

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
            // Keeps a card's delegate, and its hover, while others come and go.
            model: ScriptModel {
                values: root.shown
            }

            Item {
                id: entry

                required property var modelData
                // Read up front: the notification may be gone by destruction.
                readonly property int notifId: entry.modelData.id

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

                // Hovering pauses the expiry, so a notification being read
                // does not vanish mid-sentence. Expiry only takes the popup
                // down: what it leaves is the service's to decide.
                HoverHandler {
                    id: cardHover

                    onHoveredChanged: Notifs.hover(entry.notifId, cardHover.hovered)
                }

                // A card pushed off the stack under the pointer never reports
                // the pointer leaving.
                Component.onDestruction: Notifs.hover(entry.notifId, false)
            }
        }
    }
}

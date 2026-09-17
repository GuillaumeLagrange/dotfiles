// A panel you click open and click away to dismiss: the network and bluetooth
// ones, which hold switches and a passphrase field.
//
// Its own layer-shell window rather than a BubbleWindow, for two reasons a
// PopupWindow cannot give: keyboard focus, asked for `OnDemand` so the bar
// itself never takes focus from the focused app, and a surface that covers the
// screen, so a click anywhere dismisses it - including on the bar, which a
// popup grab does not report.
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs

PanelWindow {
    id: root

    required property Item target
    property int pad: Theme.popupPad
    // A fixed width for panels whose rows all fill it and so report no width
    // of their own; 0 sizes the bubble to its content.
    property int panelWidth: 0

    // Sampled when the panel opens: mapping functions are not reactive.
    property real triggerCenter: 0
    property real triggerTop: 0

    default property alias content: holder.data
    readonly property Item item: holder.children.length > 0 ? holder.children[0] : null

    signal shown
    signal hidden

    function open(): void {
        const trigger = root.target.mapToItem(null, 0, 0, root.target.width, root.target.height);
        root.triggerCenter = trigger.x + trigger.width / 2;
        root.triggerTop = trigger.y;
        root.visible = true;
        root.shown();
    }

    function close(): void {
        root.visible = false;
    }

    function toggle(): void {
        if (root.visible)
            root.close();
        else
            root.open();
    }

    onVisibleChanged: if (!root.visible)
        root.hidden()

    screen: root.target.QsWindow.window?.screen ?? null
    visible: false
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    Item {
        id: field

        anchors.fill: parent
        focus: true

        Keys.onEscapePressed: root.close()

        TapHandler {
            id: backdrop

            // Whether the press in flight started on the panel. A handler on an
            // ancestor is told about taps its children took, and the panel moves
            // under the pointer as rows expand, so the press is what decides.
            property bool onPanel: false

            acceptedButtons: Qt.AllButtons

            onPressedChanged: {
                if (!backdrop.pressed)
                    return;
                const local = backdrop.point.position;
                backdrop.onPanel = local.x >= bubble.x && local.x <= bubble.x + bubble.width && local.y >= bubble.y && local.y <= bubble.y + bubble.height;
            }

            onSingleTapped: if (!backdrop.onPanel)
                root.close()
        }

        Bubble {
            id: bubble

            width: root.panelWidth > 0 ? root.panelWidth : (root.item ? root.item.implicitWidth : 0) + root.pad * 2
            height: (root.item ? root.item.implicitHeight : 0) + root.pad * 2 + bubble.tailHeight
            x: Math.max(4, Math.min(field.width - width - 4, root.triggerCenter - width / 2))
            // The bar window sits at the bottom of the output, so the trigger's
            // y inside it lands this far up the screen.
            y: field.height - Theme.windowHeight + root.triggerTop - Theme.popupGap - height
            tailX: root.triggerCenter - bubble.x

            Item {
                id: holder

                anchors.fill: parent
                anchors.margins: root.pad
                anchors.bottomMargin: root.pad + bubble.tailHeight
            }
        }
    }
}

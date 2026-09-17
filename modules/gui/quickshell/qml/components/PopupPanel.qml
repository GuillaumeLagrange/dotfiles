// A panel that opens on hover rather than on a click.
//
// The window is exactly the bubble, placed with layer-shell margins, and not
// the screen-covering surface ClickPanel uses: a hover panel must leave the
// rest of the screen hoverable, and a surface anchored to all four edges only
// learns its size from the compositor after it maps - a layer surface that
// maps at 0x0 commits an empty input region and never gets it back.
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs

PanelWindow {
    id: root

    required property Item target
    property bool triggerHovered: false
    property int pad: Theme.popupPad
    // Rows that fill the width report no implicit width of their own, so a
    // panel whose content is all fill-width rows would collapse without it.
    property int minContentWidth: 0
    readonly property bool open: gate.open

    // Dismiss while the pointer is still on the panel: the gate reopens when
    // the pointer leaves and comes back, which is what a hover panel should do
    // after an action that moves you somewhere else.
    function close(): void {
        gate.open = false;
    }

    default property alias content: holder.data
    readonly property Item item: holder.children.length > 0 ? holder.children[0] : null

    // Sampled when the panel opens: mapping functions are not reactive.
    property real triggerCenter: 0
    property real triggerTop: 0

    function place(): void {
        const trigger = root.target.mapToItem(null, 0, 0, root.target.width, root.target.height);
        root.triggerCenter = trigger.x + trigger.width / 2;
        root.triggerTop = trigger.y;
    }

    // Placed before the surface maps, and again while open for a panel that
    // grows (a track name, a month with six rows) or a pill that moves.
    onTriggerHoveredChanged: if (root.triggerHovered)
        root.place()
    onWidthChanged: if (root.visible)
        root.place()

    screen: root.target.QsWindow.window?.screen ?? null
    visible: gate.open
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay

    implicitWidth: Math.max(root.minContentWidth, root.item ? root.item.implicitWidth : 0) + root.pad * 2
    implicitHeight: (root.item ? root.item.implicitHeight : 0) + root.pad * 2 + bubble.tailHeight

    anchors {
        bottom: true
        left: true
    }

    margins {
        left: {
            const screenWidth = root.screen ? root.screen.width : 0;
            return Math.max(4, Math.min(screenWidth - root.width - 4, root.triggerCenter - root.width / 2));
        }
        // The bar window sits at the bottom of the output, so the trigger's y
        // inside it is this far up from the bottom edge.
        bottom: Theme.windowHeight - root.triggerTop + Theme.popupGap
    }

    property HoverGate gate: HoverGate {
        triggerHovered: root.triggerHovered
        panelHovered: hover.hovered
    }

    Bubble {
        id: bubble

        anchors.fill: parent
        tailX: root.triggerCenter - root.margins.left

        HoverHandler {
            id: hover
        }

        Item {
            id: holder

            anchors.fill: parent
            anchors.margins: root.pad
            anchors.bottomMargin: root.pad + bubble.tailHeight
        }
    }
}

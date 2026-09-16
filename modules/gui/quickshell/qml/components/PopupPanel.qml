// Chrome and hover lifetime for the three bar panels (media, calendar, quick
// settings). Anchored above its trigger and slid back on screen if it would
// overflow, so a panel never needs a hardcoded offset from the screen edge.
//
// The content item must `anchors.fill: parent` and carry implicit sizes (a
// ColumnLayout/RowLayout does): the window sizes itself from them.
import QtQuick
import Quickshell
import qs

PopupWindow {
    id: root

    required property Item target
    property bool triggerHovered: false
    property int pad: Theme.popupPad
    // Rows that fill the width report no implicit width of their own, so a
    // panel whose content is all fill-width rows would collapse. eww expressed
    // the same floor as a CSS min-width.
    property int minContentWidth: 0
    readonly property bool open: gate.open

    default property alias content: holder.data
    readonly property Item item: holder.children.length > 0 ? holder.children[0] : null

    anchor {
        item: root.target
        edges: Edges.Top
        gravity: Edges.Top
        margins.bottom: 4
        adjustment: PopupAdjustment.SlideX
    }

    visible: gate.open
    color: "transparent"
    implicitWidth: Math.max(minContentWidth, item ? item.implicitWidth : 0) + pad * 2
    implicitHeight: (item ? item.implicitHeight : 0) + pad * 2

    Rectangle {
        anchors.fill: parent
        radius: 8
        color: Theme.drawerBg
        border.width: 1
        border.color: Theme.border

        HoverHandler {
            onHoveredChanged: gate.panelHovered = hovered
        }

        Item {
            id: holder
            anchors.fill: parent
            anchors.margins: root.pad
        }
    }

    HoverGate {
        id: gate
        triggerHovered: root.triggerHovered
    }
}

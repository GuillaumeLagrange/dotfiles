// Hover tooltip for a bar item. Qt Quick Controls' ToolTip opens its own
// top-level window, which layer-shell surfaces cannot parent; a Quickshell
// PopupWindow anchored to the item is the supported route.
import QtQuick
import Quickshell
import qs

PopupWindow {
    id: root

    required property Item target
    property string text: ""

    anchor {
        item: root.target
        edges: Edges.Top
        gravity: Edges.Top
        margins.bottom: 6
        adjustment: PopupAdjustment.SlideX
    }

    visible: true
    color: "transparent"
    implicitWidth: body.implicitWidth + 20
    implicitHeight: body.implicitHeight + 12

    Rectangle {
        anchors.fill: parent
        radius: 6
        color: Theme.drawerBg
        border.width: 1
        border.color: Theme.border

        Text {
            id: body
            anchors.centerIn: parent
            text: root.text
            color: Theme.fg
            font.family: Theme.mono
            font.pixelSize: 11
            textFormat: Text.PlainText
        }
    }
}

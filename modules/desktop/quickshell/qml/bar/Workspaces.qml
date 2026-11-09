import QtQuick
import qs
import qs.services

Row {
    id: root

    required property string monitor

    spacing: 2

    Repeater {
        model: Niri.workspaces.filter(ws => ws.output === root.monitor)

        delegate: Rectangle {
            id: cell

            required property var modelData
            readonly property bool marked: modelData.is_focused || modelData.is_active

            implicitWidth: label.implicitWidth + 14
            // Full bar height so the underline sits on the bar's bottom edge.
            height: Theme.barHeight
            color: modelData.is_urgent ? "#EB4D4B" : modelData.is_focused ? Theme.orange : modelData.is_active ? Theme.blue : hover.hovered ? Theme.alpha("#000000", 0.2) : "transparent"

            Text {
                id: label
                anchors.centerIn: parent
                text: cell.modelData.name
                color: cell.marked || cell.modelData.is_urgent ? Theme.ink : Theme.fg
                font.family: Theme.mono
                font.pixelSize: Theme.fontSize
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 3
                color: Theme.fg
                visible: cell.marked
            }

            HoverHandler {
                id: hover
                cursorShape: Qt.PointingHandCursor
            }

            TapHandler {
                onSingleTapped: Niri.focusWorkspace(cell.modelData.name)
            }
        }
    }
}

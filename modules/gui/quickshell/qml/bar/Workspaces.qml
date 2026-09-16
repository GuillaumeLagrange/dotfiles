import QtQuick
import qs
import qs.services

Row {
    id: root

    required property string monitor

    // Every state keeps the same padding: the highlight is a background on the
    // cell, so state-dependent padding would resize the pill and shift the row's
    // rhythm as focus moves.
    spacing: 2

    Repeater {
        model: Niri.workspaces.filter(ws => ws.output === root.monitor)

        delegate: Item {
            id: cell

            required property var modelData

            implicitWidth: name.implicitWidth + 14
            // Cells carry the bar's full height so the focus underline sits on
            // the bar's bottom edge. A positioner computes its own implicit
            // height, so it cannot be the source of this.
            height: Theme.barHeight

            readonly property color bg: modelData.is_urgent ? "#EB4D4B" : modelData.is_focused ? Theme.orange : modelData.is_active ? Theme.blue : "transparent"
            readonly property bool marked: modelData.is_focused || modelData.is_active

            Rectangle {
                anchors.fill: parent
                color: hover.hovered && cell.bg.a === 0 ? Theme.alpha("#000000", 0.2) : cell.bg
            }

            Text {
                id: name
                anchors.centerIn: parent
                text: cell.modelData.name
                color: cell.marked || cell.modelData.is_urgent ? Theme.ink : Theme.fg
                font.family: Theme.mono
                font.pixelSize: Theme.fontSize
            }

            // The underline is drawn, not a border: a border would offset the
            // cell's content box and make marked cells a different size.
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 3
                color: Theme.fg
                visible: cell.marked
            }

            HoverHandler {
                id: hover
            }

            TapHandler {
                onSingleTapped: Niri.focusWorkspace(cell.modelData.name)
            }
        }
    }
}

import QtQuick
import qs
import qs.services

Row {
    id: root

    required property string monitor

    spacing: Theme.gap

    Repeater {
        model: Niri.workspaces.filter(ws => ws.output === root.monitor)

        // One pill per workspace: its number, then its strip when it has windows,
        // inside a single outline in the number's colour, so the two read as a pair.
        delegate: Item {
            id: entry

            required property var modelData
            readonly property bool marked: modelData.is_focused || modelData.is_active
            readonly property Item cell: box
            readonly property Item strip: layout
            readonly property color accent: modelData.is_urgent ? "#EB4D4B" : modelData.is_focused ? Theme.orange : modelData.is_active ? Theme.blue : Theme.alpha(Theme.fg, hover.hovered ? 0.28 : 0.16)
            readonly property int radius: Theme.pillRadius

            implicitWidth: group.implicitWidth
            implicitHeight: Theme.pillHeight

            Rectangle {
                anchors.fill: parent
                radius: entry.radius
                color: Theme.alpha("#000000", 0.25)
            }

            Row {
                id: group

                height: parent.height
                // Room around the strip inside the pill, on top of its own 5px.
                spacing: layout.visible ? 4 : 0
                rightPadding: layout.visible ? 4 : 0

                Rectangle {
                    id: box

                    implicitWidth: label.implicitWidth + 14
                    height: parent.height
                    topLeftRadius: entry.radius
                    bottomLeftRadius: entry.radius
                    topRightRadius: layout.visible ? 0 : entry.radius
                    bottomRightRadius: layout.visible ? 0 : entry.radius
                    color: entry.accent

                    Text {
                        id: label
                        anchors.centerIn: parent
                        text: entry.modelData.name
                        color: entry.marked || entry.modelData.is_urgent ? Theme.ink : Theme.fg
                        font.family: Theme.mono
                        font.pixelSize: Theme.fontSize
                        font.bold: true
                    }

                    HoverHandler {
                        id: hover
                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        onSingleTapped: Niri.focusWorkspace(entry.modelData.name)
                    }
                }

                Strip {
                    id: layout
                    anchors.verticalCenter: parent.verticalCenter
                    // Inset from the outline, so the rails do not run along it.
                    height: parent.height - 8
                    workspace: entry.modelData
                }
            }

            // Drawn over the content so the number's fill does not cover it.
            Rectangle {
                anchors.fill: parent
                radius: entry.radius
                color: "transparent"
                border.width: 1
                border.color: entry.accent
            }
        }
    }
}

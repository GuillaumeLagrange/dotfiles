// Native SNI host. Menus are rendered by QsMenuAnchor, so nm-applet and
// blueman-applet keep working exactly as they do under eww's systray.
import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import Quickshell.Widgets
import qs

Row {
    id: root

    spacing: Theme.gap
    leftPadding: 4
    rightPadding: 4

    Repeater {
        model: SystemTray.items

        delegate: Item {
            id: entry

            required property SystemTrayItem modelData

            implicitWidth: 14
            height: Theme.pillHeight

            IconImage {
                anchors.centerIn: parent
                source: entry.modelData.icon
                implicitSize: 14
            }

            HoverHandler {
                cursorShape: Qt.PointingHandCursor
            }

            TapHandler {
                acceptedButtons: Qt.LeftButton
                onSingleTapped: {
                    if (entry.modelData.onlyMenu)
                        menu.open();
                    else
                        entry.modelData.activate();
                }
            }

            TapHandler {
                acceptedButtons: Qt.MiddleButton
                onSingleTapped: entry.modelData.secondaryActivate()
            }

            TapHandler {
                acceptedButtons: Qt.RightButton
                onSingleTapped: menu.open()
            }

            QsMenuAnchor {
                id: menu

                menu: entry.modelData.menu

                anchor {
                    item: entry
                    edges: Edges.Top
                    gravity: Edges.Top
                    margins.bottom: 6
                }
            }
        }
    }
}

// The start menu's hot corner: the pointer resting 150 ms in the bar's
// bottom-left corner, as long as niri's top-left one asks, opens the menu.
// The item spans the bar window's height so the menu sits above the bar; only
// its bottom few pixels are the corner.
import QtQuick
import qs.popups

Item {
    id: root

    readonly property int size: 4
    // Cleared while the pointer is in the corner the menu closed over: the
    // menu's window covered it, so the pointer re-enters the corner without
    // having moved, and that must not open the menu again.
    property bool armed: true

    implicitWidth: root.size

    Item {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        width: root.size
        height: root.size

        HoverHandler {
            id: corner

            onHoveredChanged: {
                if (!corner.hovered) {
                    root.armed = true;
                    dwell.stop();
                } else if (root.armed) {
                    dwell.restart();
                }
            }
        }
    }

    Timer {
        id: dwell

        interval: 150
        onTriggered: menu.open()
    }

    StartMenu {
        id: menu

        target: root
        onHidden: root.armed = !(menu.pointer.x < root.size && menu.pointer.y >= menu.height - root.size)
    }
}

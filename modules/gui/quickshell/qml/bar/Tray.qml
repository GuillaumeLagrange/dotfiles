// Native SNI host, folded behind three dots: a row of applet icons is noise
// most of the time, so the pill keeps the bar to a fixed width and unfolds the
// icons inline when the pointer is on it - a drawer in the bar itself, not a
// panel above it, so nothing has to survive the pointer crossing a gap.
import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import Quickshell.Widgets
import qs
import qs.components

Rectangle {
    id: root

    readonly property bool unfolded: hover.hovered || menu.visible

    visible: SystemTray.items.values.length > 0
    implicitWidth: (root.unfolded ? icons.implicitWidth : dots.implicitWidth) + Theme.pillPad * 2
    implicitHeight: Theme.pillHeight
    radius: Theme.pillRadius
    color: root.unfolded ? Theme.alpha(Theme.fg, 0.2) : Theme.alpha(Theme.fg, 0.14)
    // The drawer slides rather than snapping the rest of the bar sideways.
    clip: true

    Behavior on implicitWidth {
        NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
        }
    }

    Glyph {
        id: dots

        anchors.centerIn: parent
        visible: !root.unfolded
        text: Config.glyph.more
        color: Theme.fg
    }

    Row {
        id: icons

        anchors.centerIn: parent
        visible: root.unfolded
        spacing: 10

        Repeater {
            model: SystemTray.items

            delegate: Item {
                id: entry

                required property SystemTrayItem modelData

                implicitWidth: 18
                implicitHeight: 18

                IconImage {
                    anchors.centerIn: parent
                    source: entry.modelData.icon
                    implicitSize: 18
                    opacity: iconHover.hovered ? 1 : 0.85
                }

                HoverHandler {
                    id: iconHover

                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    onSingleTapped: {
                        if (entry.modelData.onlyMenu)
                            root.openMenu(entry.modelData.menu);
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
                    onSingleTapped: root.openMenu(entry.modelData.menu)
                }
            }
        }
    }

    function openMenu(handle: var): void {
        menu.handle = handle;
        menu.open();
    }

    HoverHandler {
        id: hover
    }

    TrayMenu {
        id: menu

        target: root
    }
}

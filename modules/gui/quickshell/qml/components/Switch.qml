// The bar's on/off control: quick settings toggles, radios, VPN profiles.
import QtQuick
import qs

Rectangle {
    id: root

    required property bool on
    // A switch with nothing to switch - a wired device with no cable in it -
    // still shows its state, greyed and inert.
    property bool live: true
    // Off when the whole row is the click target: a handler on the row would
    // otherwise also see the tap this one took, and toggle twice.
    property bool interactive: true

    signal toggled

    implicitWidth: 34
    implicitHeight: 18
    radius: 99
    opacity: root.live ? 1 : 0.4
    color: root.on ? Theme.blue : Theme.alpha(Theme.fg, 0.14)

    Rectangle {
        width: 14
        height: 14
        radius: 99
        anchors.verticalCenter: parent.verticalCenter
        x: root.on ? parent.width - width - 2 : 2
        color: root.on ? Theme.ink : Theme.alpha(Theme.fg, 0.55)

        Behavior on x {
            NumberAnimation {
                duration: 120
            }
        }
    }

    HoverHandler {
        enabled: root.live && root.interactive
        cursorShape: Qt.PointingHandCursor
    }

    TapHandler {
        enabled: root.live && root.interactive
        onSingleTapped: root.toggled()
    }
}

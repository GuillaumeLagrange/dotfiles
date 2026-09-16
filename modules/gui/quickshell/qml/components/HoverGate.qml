// Open/close state for a hover-driven panel. eww needed two runtime flag files
// and an mtime comparison for this, because GTK fires hover-lost as the pointer
// crosses a popup's child widgets; QML's HoverHandler reports the subtree, so a
// dwell timer and a close debounce are the whole machine.
import QtQuick

QtObject {
    id: root

    property bool triggerHovered: false
    property bool panelHovered: false
    property int openDelay: 500
    property int closeDelay: 300

    readonly property bool wanted: triggerHovered || panelHovered
    property bool open: false

    onWantedChanged: {
        if (wanted) {
            closeTimer.stop();
            if (!open)
                openTimer.restart();
        } else {
            openTimer.stop();
            if (open)
                closeTimer.restart();
        }
    }

    property Timer openTimer: Timer {
        interval: root.openDelay
        onTriggered: root.open = true
    }

    property Timer closeTimer: Timer {
        interval: root.closeDelay
        onTriggered: root.open = false
    }
}

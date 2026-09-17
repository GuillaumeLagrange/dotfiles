// Open/close state for a hover-driven panel: a dwell before opening, so
// crossing a pill does not flash it up, and a debounce before closing, so the
// gap between the pill and the panel can be crossed.
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

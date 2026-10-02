// A volume bar you can drag, click or scroll, with an optional peak meter
// drawn inside the fill.
import QtQuick
import qs

Item {
    id: root

    property real value: 0
    // The node's pre-volume level, as PwNodePeakMonitor reports it; negative
    // hides the meter.
    property real peak: -1
    property color tint: Theme.blue
    property bool live: true

    // Emitted while dragging as well as on release: Pipewire takes every step.
    signal moved(real value)

    function valueAt(x: real): real {
        return Math.max(0, Math.min(1, x / Math.max(1, root.width)));
    }

    implicitHeight: 18
    opacity: root.live ? 1 : 0.4

    // Overhangs the track so the thumb at either end still sits inside it.
    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: -5
        anchors.rightMargin: -5
        radius: 6
        color: area.pressed ? Theme.alpha(Theme.fg, 0.1) : (area.containsMouse ? Theme.alpha(Theme.fg, 0.06) : "transparent")
    }

    Rectangle {
        id: track

        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: 6
        radius: 99
        color: Theme.alpha("#000000", 0.35)

        Rectangle {
            width: parent.width * Math.max(0, Math.min(1, root.value))
            height: parent.height
            radius: 99
            color: root.tint
        }

        // Scaled by the volume, both being on the same cube-root scale, so it
        // shows what comes out and never runs past the thumb.
        Rectangle {
            visible: root.peak >= 0
            width: parent.width * Math.max(0, Math.min(1, root.peak)) * Math.max(0, Math.min(1, root.value))
            height: parent.height
            radius: 99
            color: Qt.lighter(root.tint, 1.35)
        }
    }

    Rectangle {
        width: 12
        height: 12
        radius: 99
        anchors.verticalCenter: parent.verticalCenter
        x: Math.max(0, Math.min(root.width - width, root.value * root.width - width / 2))
        color: Theme.fg
        border.width: 1
        border.color: Theme.alpha("#000000", 0.4)
    }

    // Tap/DragHandlers only report on release or past the drag threshold.
    MouseArea {
        id: area

        anchors.fill: parent
        enabled: root.live
        hoverEnabled: true
        preventStealing: true
        cursorShape: Qt.PointingHandCursor
        onPressed: mouse => root.moved(root.valueAt(mouse.x))
        onPositionChanged: mouse => {
            if (area.pressed)
                root.moved(root.valueAt(mouse.x));
        }
        onWheel: wheel => root.moved(Math.max(0, Math.min(1, root.value + (wheel.angleDelta.y > 0 ? 0.02 : -0.02))))
    }
}

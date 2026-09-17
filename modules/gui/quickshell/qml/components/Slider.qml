// A volume bar you can drag, click or scroll, with an optional peak meter
// drawn behind the fill.
import QtQuick
import qs

Item {
    id: root

    property real value: 0
    // 0-1 level drawn behind the fill; negative hides the meter.
    property real peak: -1
    property color tint: Theme.blue
    property bool live: true

    // Emitted while dragging as well as on release: Pipewire takes every step.
    signal moved(real value)

    function valueAt(x: real): real {
        return Math.max(0, Math.min(1, x / Math.max(1, root.width)));
    }

    implicitHeight: 14
    opacity: root.live ? 1 : 0.4

    Rectangle {
        id: track

        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: 6
        radius: 99
        color: Theme.alpha("#000000", 0.35)

        Rectangle {
            visible: root.peak >= 0
            width: parent.width * Math.max(0, Math.min(1, root.peak))
            height: parent.height
            radius: 99
            color: Theme.alpha(root.tint, 0.3)
        }

        Rectangle {
            width: parent.width * Math.max(0, Math.min(1, root.value))
            height: parent.height
            radius: 99
            color: root.tint
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

    HoverHandler {
        enabled: root.live
        cursorShape: Qt.PointingHandCursor
    }

    TapHandler {
        enabled: root.live
        onSingleTapped: point => root.moved(root.valueAt(point.position.x))
    }

    DragHandler {
        id: drag

        enabled: root.live
        target: null
        xAxis.enabled: true
        yAxis.enabled: false
        onCentroidChanged: if (drag.active)
            root.moved(root.valueAt(drag.centroid.position.x))
    }

    WheelHandler {
        enabled: root.live
        onWheel: event => root.moved(Math.max(0, Math.min(1, root.value + (event.angleDelta.y > 0 ? 0.02 : -0.02))))
    }
}

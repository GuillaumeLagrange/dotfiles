// A badge in the bar: rounded background, one line of text, optional tooltip,
// and the three input gestures the eww widgets used (click, right-click, scroll).
import QtQuick
import Quickshell
import qs

Rectangle {
    id: root

    property string text: ""
    property string tooltip: ""
    property color textColor: Theme.ink
    property int hPad: Theme.pillPad
    property alias font: label.font
    property alias textFormat: label.textFormat
    // Cap the label and elide past it, for texts that are not bounded by nature
    // (window titles, track names). 0 leaves the pill content-sized.
    property int maxTextWidth: 0
    readonly property bool hovered: hover.hovered

    signal clicked
    signal rightClicked
    signal scrolled(int dy)

    implicitWidth: (maxTextWidth > 0 ? Math.min(label.implicitWidth, maxTextWidth) : label.implicitWidth) + hPad * 2
    implicitHeight: Theme.pillHeight
    radius: Theme.pillRadius

    Text {
        id: label
        anchors.centerIn: parent
        width: root.maxTextWidth > 0 ? root.implicitWidth - root.hPad * 2 : implicitWidth
        text: root.text
        color: root.textColor
        elide: Text.ElideRight
        font.family: Theme.mono
        font.pixelSize: Theme.fontSize
    }

    HoverHandler {
        id: hover
    }

    TapHandler {
        acceptedButtons: Qt.LeftButton
        onSingleTapped: root.clicked()
    }

    TapHandler {
        acceptedButtons: Qt.RightButton
        onSingleTapped: root.rightClicked()
    }

    WheelHandler {
        onWheel: event => root.scrolled(event.angleDelta.y)
    }

    Timer {
        id: dwell
        interval: 400
        onTriggered: tip.active = true
    }

    onHoveredChanged: {
        if (hovered && tooltip !== "") {
            dwell.restart();
        } else {
            dwell.stop();
            tip.active = false;
        }
    }

    LazyLoader {
        id: tip
        component: Component {
            Tip {
                target: root
                text: root.tooltip
            }
        }
    }
}

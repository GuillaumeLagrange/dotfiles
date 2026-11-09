// A badge in the bar: rounded background, one line of text, optional tooltip,
// and click / right-click / scroll gestures.
import QtQuick
import Quickshell
import qs

Rectangle {
    id: root

    // Pill texts are "<glyph> <value>". The glyph is split out so Glyph can
    // draw it: a private-use codepoint has no relation to the line box the
    // label is laid out in, so left in the Text it renders off-centre.
    // Splitting here covers texts pushed in from a script too.
    property string text: ""
    readonly property string glyph: {
        const t = root.text;
        let i = 0;
        while (i < t.length) {
            const cp = t.codePointAt(i);
            const pua = (cp >= 0xE000 && cp <= 0xF8FF) || (cp >= 0xF0000 && cp <= 0xFFFFD) || (cp >= 0x100000 && cp <= 0x10FFFD);
            if (!pua && cp !== 0x20)
                break;
            i += cp > 0xFFFF ? 2 : 1;
        }
        return t.slice(0, i).trim();
    }
    readonly property string label: root.glyph === "" ? root.text : root.text.slice(root.glyph.length).trim()
    property string tooltip: ""
    property color textColor: Theme.ink
    property int hPad: Theme.pillPad
    property alias font: label.font
    property alias textFormat: label.textFormat
    // Cap the label and elide past it, for texts that are not bounded by nature
    // (window titles, track names). 0 leaves the pill content-sized.
    property int maxTextWidth: 0
    // A pill that does nothing on click should not pretend otherwise, so the
    // pointer is opt-in.
    property bool interactive: false
    readonly property bool hovered: hover.hovered

    signal clicked
    signal rightClicked
    signal scrolled(int dy)

    implicitWidth: row.implicitWidth + hPad * 2
    implicitHeight: Theme.pillHeight
    radius: Theme.pillRadius

    Row {
        id: row

        anchors.centerIn: parent
        spacing: root.glyph !== "" && root.label !== "" ? Theme.glyphGap : 0

        Glyph {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.glyph !== ""
            text: root.glyph
            color: root.textColor
            size: label.font.pixelSize
        }

        Text {
            id: label

            anchors.verticalCenter: parent.verticalCenter
            visible: text !== ""
            width: root.maxTextWidth > 0 ? Math.min(implicitWidth, root.maxTextWidth) : implicitWidth
            text: root.label
            color: root.textColor
            elide: Text.ElideRight
            font.family: Theme.mono
            font.pixelSize: Theme.fontSize
        }
    }

    HoverHandler {
        id: hover

        cursorShape: root.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
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

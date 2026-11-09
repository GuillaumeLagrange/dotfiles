// A panel's title row: the pill's glyph in an accent chip, the title, and
// optional trailing controls (children go to the right end).
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs

RowLayout {
    id: root

    property string glyph: ""
    property string text: ""
    property color accent: Theme.blue
    default property alias trailing: slot.data

    Layout.fillWidth: true
    spacing: 8

    Rectangle {
        id: chip

        // Device pixels per logical pixel: offsets are snapped to these, not to
        // whole logical pixels, which are 1.6 device pixels at fractional scales.
        readonly property real dpr: QsWindow.window ? QsWindow.window.devicePixelRatio : 1

        visible: root.glyph !== ""
        implicitWidth: 22
        implicitHeight: 22
        radius: Theme.pillRadius
        color: root.accent

        // Centred on the exact ink box: Glyph floors its own bounds to whole
        // logical pixels, which leaves up to one of them of slack on one side.
        Glyph {
            id: mark

            readonly property real inkCenterX: mark.qtInk.x - mark.inkLeft + mark.qtInk.width / 2
            readonly property real inkCenterY: (mark.bounds[0] + mark.bounds[1]) / 2 - mark.inkTop

            x: Math.round((chip.width / 2 - mark.inkCenterX) * chip.dpr) / chip.dpr
            y: Math.round((chip.height / 2 - mark.inkCenterY) * chip.dpr) / chip.dpr
            text: root.glyph
            color: Theme.ink
            size: 13
        }
    }

    Text {
        Layout.fillWidth: true
        text: root.text
        elide: Text.ElideRight
        color: Theme.fg
        font.family: Theme.ui
        font.pixelSize: 13
        font.weight: Font.DemiBold
    }

    Row {
        id: slot

        Layout.alignment: Qt.AlignVCenter
        spacing: 8
    }
}

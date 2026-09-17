// Hover tooltip for a bar item. Qt Quick Controls' ToolTip opens its own
// top-level window, which layer-shell surfaces cannot parent; the same bubble
// the panels use, anchored to the item, is the supported route.
import QtQuick
import qs
import qs.components

BubbleWindow {
    id: root

    property string text: ""

    pad: 8
    bodyRadius: 6
    visible: true

    Text {
        anchors.fill: parent
        text: root.text
        color: Theme.fg
        // A tooltip with several lines is a table (the Claude usage one lines
        // up columns with padding); centring each line separately shears it.
        horizontalAlignment: root.text.includes("\n") ? Text.AlignLeft : Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        font.family: Theme.mono
        font.pixelSize: 11
        textFormat: Text.PlainText
    }
}

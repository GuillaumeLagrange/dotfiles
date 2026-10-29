// A round icon button: a glyph centred on its ink inside a disc that tints
// on hover.
import QtQuick
import qs

Rectangle {
    id: root

    property string glyph: ""
    property int glyphSize: 13
    // Filled buttons carry the primary action and take a colour of their own;
    // the rest are ghosts that only show a disc under the pointer.
    property bool filled: false
    property color tint: Theme.fg
    readonly property bool hovered: hover.hovered

    signal clicked

    implicitWidth: Math.round(root.glyphSize * 2.2)
    implicitHeight: root.implicitWidth
    radius: width / 2
    color: {
        if (root.filled)
            return root.hovered ? Qt.lighter(root.tint, 1.15) : root.tint;
        return root.hovered ? Theme.hoverFill : "transparent";
    }

    Glyph {
        anchors.centerIn: parent
        text: root.glyph
        size: root.glyphSize
        color: root.filled ? Theme.ink : (root.hovered ? Theme.fg : Theme.dim)
    }

    HoverHandler {
        id: hover

        cursorShape: Qt.PointingHandCursor
    }

    TapHandler {
        onSingleTapped: root.clicked()
    }
}

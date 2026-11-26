// An icon from the theme or a file, or a glyph tile when there is none to
// show: quickshell draws a magenta checkerboard for a name the icon theme
// lacks, and an image that fails to load draws nothing.
import QtQuick
import Quickshell
import Quickshell.Widgets
import qs

Item {
    id: root

    // An icon theme name; `source` takes a path or URL instead.
    property string name: ""
    property string source: ""
    property string glyph: Config.glyph.apps
    property color glyphColor: Theme.dim
    property int size: 28

    readonly property string resolved: root.source !== "" ? root.source : root.name !== "" ? Quickshell.iconPath(root.name, true) : ""
    readonly property bool missing: root.resolved === "" || image.status === Image.Error

    implicitWidth: root.size
    implicitHeight: root.size

    IconImage {
        id: image

        anchors.fill: parent
        visible: !root.missing
        source: root.resolved
        implicitSize: root.size
        asynchronous: true
    }

    Rectangle {
        anchors.fill: parent
        visible: root.missing
        radius: Theme.rowRadius
        color: Theme.well

        Glyph {
            anchors.centerIn: parent
            text: root.glyph
            color: root.glyphColor
            size: Math.round(root.size * 0.57)
        }
    }
}

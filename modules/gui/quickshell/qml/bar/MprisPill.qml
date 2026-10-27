// Bar pill: source glyph + title + play/pause, in the active player's colour.
// Hovering it opens the now-playing panel; clicking it raises the player.
import QtQuick
import QtQuick.Layouts
import qs
import qs.popups
import qs.services

Rectangle {
    id: root

    readonly property var player: Media.active
    readonly property bool playing: root.player !== null && root.player.isPlaying
    readonly property color railColor: root.player !== null ? Media.colorFor(root.player) : Theme.grey
    readonly property string title: {
        if (root.player === null)
            return "";
        const t = root.player.trackTitle;
        return t.length > 34 ? t.slice(0, 34) + "..." : t;
    }

    visible: root.player !== null
    implicitWidth: rail.width + 8 + layout.implicitWidth + 6
    implicitHeight: Theme.pillHeight
    radius: Theme.pillRadius
    color: Theme.alpha("#000000", 0.22)

    Rectangle {
        id: rail
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 2
        color: root.railColor
    }

    // The play/pause target is the pill's whole right end, not just the glyph.
    Item {
        id: toggleZone
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        width: toggleGlyph.width + layout.anchors.rightMargin + layout.spacing

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: Theme.pillRadius - 1
            color: toggleHover.hovered ? Theme.alpha(root.railColor, 0.2) : "transparent"
        }

        HoverHandler {
            id: toggleHover

            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            onSingleTapped: {
                if (root.player !== null)
                    root.player.togglePlaying();
            }
        }
    }

    RowLayout {
        id: layout
        anchors.left: rail.right
        anchors.leftMargin: 8
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        spacing: 7

        Text {
            Layout.alignment: Qt.AlignVCenter
            text: root.player !== null ? Media.iconFor(root.player) : ""
            color: root.railColor
            font.family: Theme.icon
            font.pixelSize: 12
        }

        Text {
            Layout.alignment: Qt.AlignVCenter
            text: root.title
            color: root.playing ? Theme.fg : Theme.alpha(Theme.fg, 0.55)
            font.family: Theme.mono
            font.pixelSize: Theme.fontSize
            font.weight: Font.Medium
        }

        Text {
            id: toggleGlyph

            Layout.alignment: Qt.AlignVCenter
            text: root.playing ? Config.glyph.pause : Config.glyph.play
            color: toggleHover.hovered ? root.railColor : Theme.alpha(Theme.fg, 0.85)
            font.family: Theme.icon
            font.pixelSize: 11
        }
    }

    HoverHandler {
        id: hover

        cursorShape: Qt.PointingHandCursor
    }

    TapHandler {
        onSingleTapped: {
            // The play/pause zone has its own tap.
            if (root.player === null || toggleHover.hovered)
                return;
            root.player.raise();
            panel.close();
        }
    }

    NowPlaying {
        id: panel

        target: root
        triggerHovered: hover.hovered
    }
}

// Bar pill: source glyph + title + play/pause, in the active player's colour.
// Three click zones: the glyph, which turns into an up chevron while the pill
// is hovered and opens the now-playing panel (as Mod+P does), the title, which
// raises the player, and the right end, which plays or pauses.
import QtQuick
import QtQuick.Layouts
import qs
import qs.components
import qs.popups
import qs.services

Rectangle {
    id: root

    required property string monitor
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

    component Zone: Item {
        id: zone

        readonly property bool hovered: zoneHover.hovered

        signal tapped

        anchors.top: parent.top
        anchors.bottom: parent.bottom

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: Theme.pillRadius - 1
            color: zone.hovered ? Theme.alpha(root.railColor, 0.2) : "transparent"
        }

        HoverHandler {
            id: zoneHover

            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            onSingleTapped: zone.tapped()
        }
    }

    Zone {
        id: expandZone

        x: layout.x + icon.x + icon.width / 2 - width / 2
        width: height
        onTapped: panel.toggle()
    }

    Zone {
        id: toggleZone

        anchors.right: parent.right
        width: toggleGlyph.width + layout.anchors.rightMargin + layout.spacing
        onTapped: {
            if (root.player !== null)
                root.player.togglePlaying();
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

        Item {
            id: icon

            // Fixed so swapping in the chevron does not shift the pill.
            Layout.preferredWidth: 14
            Layout.alignment: Qt.AlignVCenter
            implicitHeight: glyph.implicitHeight

            Glyph {
                id: glyph

                anchors.centerIn: parent
                text: pillHover.hovered ? Config.glyph.expandUp : root.player !== null ? Media.iconFor(root.player) : ""
                color: root.railColor
                size: 12
            }
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
            color: toggleZone.hovered ? root.railColor : Theme.alpha(Theme.fg, 0.85)
            font.family: Theme.icon
            font.pixelSize: 11
        }
    }

    HoverHandler {
        id: pillHover

        cursorShape: Qt.PointingHandCursor
    }

    TapHandler {
        onSingleTapped: {
            // The end zones have their own taps.
            if (root.player === null || expandZone.hovered || toggleZone.hovered)
                return;
            root.player.raise();
        }
    }

    NowPlaying {
        id: panel

        target: root
    }

    Connections {
        target: Media

        function onPanelToggleRequested(): void {
            if (root.visible && root.monitor === Niri.focusedOutput)
                panel.toggle();
        }
    }
}

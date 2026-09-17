// Now-playing panel: one colour-railed row per player. The position and the
// title marquee are polled off MprisPlayer, and only while the panel is open.
import QtQuick
import QtQuick.Layouts
import qs
import qs.components
import qs.services

PopupPanel {
    id: root

    minContentWidth: 540

    // A fixed-width window over the title, slid one character per tick and
    // held at each end so a scroll has a visible start and finish.
    // Leading ASCII spaces become NBSP so QML's Text can't trim them away,
    // which would otherwise make the frame look like it jumped ahead.
    function scrollFrames(title) {
        const WINDOW = 30, START_HOLD = 3, END_HOLD = 8;
        if (title.length <= WINDOW)
            return [title.padEnd(WINDOW)];
        const keepLeadingSpace = frame => {
            const stripped = frame.replace(/^ +/, "");
            return "\u00a0".repeat(frame.length - stripped.length) + stripped;
        };
        const slides = [];
        for (let i = 0; i <= title.length - WINDOW; i++)
            slides.push(keepLeadingSpace(title.substr(i, WINDOW)).padEnd(WINDOW));
        return Array(START_HOLD).fill(slides[0]).concat(slides).concat(Array(END_HOLD).fill(slides[slides.length - 1]));
    }

    // Bumped every 500ms while open to force a fresh read of MprisPlayer's
    // interpolated position; position/length only change value on this read,
    // they have no steady stream of notify signals to bind against directly.
    property int tick: 0

    ColumnLayout {
        anchors.fill: parent
        spacing: 8

        Text {
            Layout.fillWidth: true
            text: "Now Playing"
            color: Theme.grey
            font.family: Theme.mono
            font.pixelSize: 12
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 8

            Repeater {
                model: Media.players

                delegate: Rectangle {
                    id: row

                    required property var modelData

                    readonly property color rail: Media.colorFor(modelData)
                    readonly property bool playing: modelData.isPlaying
                    readonly property bool hasLength: modelData.lengthSupported && modelData.length > 0
                    readonly property double position: {
                        root.tick;
                        return modelData.position;
                    }
                    readonly property double length: {
                        root.tick;
                        return modelData.length;
                    }
                    readonly property real progress: row.hasLength ? Math.min(1, row.position / row.length) : 0
                    readonly property var frames: root.scrollFrames(modelData.trackTitle)
                    property int frameIdx: 0

                    onFramesChanged: row.frameIdx = 0

                    Layout.fillWidth: true
                    implicitHeight: inner.implicitHeight + 20
                    radius: 8
                    color: row.playing ? Theme.alpha("#000000", 0.18) : Theme.alpha("#000000", 0.10)

                    Timer {
                        interval: 180
                        running: root.open
                        repeat: true
                        onTriggered: row.frameIdx = (row.frameIdx + 1) % row.frames.length
                    }

                    RowLayout {
                        id: inner
                        anchors.fill: parent
                        anchors.margins: 10
                        anchors.rightMargin: 12
                        spacing: 12

                        Rectangle {
                            Layout.preferredWidth: 3
                            Layout.fillHeight: true
                            radius: 3
                            color: row.rail
                        }

                        Rectangle {
                            Layout.preferredWidth: 52
                            Layout.preferredHeight: 52
                            Layout.alignment: Qt.AlignVCenter
                            radius: 6
                            color: "transparent"
                            clip: true

                            Image {
                                anchors.fill: parent
                                source: row.modelData.trackArtUrl
                                visible: row.modelData.trackArtUrl !== ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                            }

                            Text {
                                anchors.centerIn: parent
                                visible: row.modelData.trackArtUrl === ""
                                text: Media.iconFor(row.modelData)
                                color: Theme.alpha(Theme.fg, 0.5)
                                font.family: Theme.icon
                                font.pixelSize: 26
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 3

                            RowLayout {
                                spacing: 6

                                Text {
                                    text: Media.iconFor(row.modelData)
                                    color: row.rail
                                    font.family: Theme.icon
                                    font.pixelSize: 11
                                }

                                // Fixed width so the row never resizes as the scroll
                                // frame's content changes width (glyphs are wider than
                                // an average char).
                                Item {
                                    Layout.preferredWidth: 280
                                    implicitHeight: title.implicitHeight
                                    clip: true

                                    Text {
                                        id: title
                                        text: row.frames[row.frameIdx]
                                        color: row.playing ? Theme.fg : Theme.alpha(Theme.fg, 0.55)
                                        font.family: Theme.mono
                                        font.pixelSize: 14
                                        font.weight: Font.Bold

                                        HoverHandler {
                                            cursorShape: Qt.PointingHandCursor
                                        }

                                        TapHandler {
                                            // Raising the window means leaving the
                                            // bar, so the panel has no reason to
                                            // stay up in front of it.
                                            onSingleTapped: {
                                                row.modelData.raise();
                                                root.close();
                                            }
                                        }
                                    }
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                visible: row.modelData.trackArtist !== ""
                                text: row.modelData.trackArtist
                                color: Theme.alpha(Theme.fg, 0.6)
                                font.family: Theme.mono
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.topMargin: 2
                                spacing: 8

                                Text {
                                    text: Media.format(row.position)
                                    color: Theme.alpha(Theme.fg, 0.55)
                                    font.family: Theme.mono
                                    font.pixelSize: 10
                                }

                                // Read-only: no click-to-seek.
                                Item {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 4
                                    visible: row.hasLength

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 99
                                        color: Theme.alpha(Theme.fg, 0.16)
                                    }

                                    Rectangle {
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        anchors.bottom: parent.bottom
                                        radius: 99
                                        width: parent.width * row.progress
                                        color: Theme.fg
                                    }
                                }

                                // A missing mpris:length is not a live stream: browsers
                                // publish the track before its duration. Hide the bar and
                                // end time rather than show a bogus 0:00 until it arrives.
                                Item {
                                    Layout.fillWidth: true
                                    visible: !row.hasLength
                                }

                                Text {
                                    visible: row.hasLength
                                    text: Media.format(row.length)
                                    color: Theme.alpha(Theme.fg, 0.55)
                                    font.family: Theme.mono
                                    font.pixelSize: 10
                                }
                            }
                        }

                        RowLayout {
                            Layout.leftMargin: 8
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 2

                            GlyphButton {
                                glyph: Config.glyph.prev
                                glyphSize: 12
                                onClicked: row.modelData.previous()
                            }

                            GlyphButton {
                                glyph: row.playing ? Config.glyph.pause : Config.glyph.play
                                glyphSize: 14
                                filled: true
                                tint: row.rail
                                onClicked: row.modelData.togglePlaying()
                            }

                            GlyphButton {
                                glyph: Config.glyph.next
                                glyphSize: 12
                                onClicked: row.modelData.next()
                            }
                        }
                    }
                }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: Media.players.length === 0
            text: "Nothing playing"
            color: Theme.grey
            horizontalAlignment: Text.AlignHCenter
            font.family: Theme.mono
            font.pixelSize: 12
        }
    }

    Timer {
        interval: 500
        running: root.open
        repeat: true
        onTriggered: root.tick++
    }
}

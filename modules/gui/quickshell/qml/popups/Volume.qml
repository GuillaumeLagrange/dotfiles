// Output, input and per-application volumes.
import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Pipewire
import qs
import qs.components
import qs.services

ClickPanel {
    id: root

    panelWidth: 340

    onHidden: root.picking = ""

    // Which device list is unfolded: "output", "input", or neither.
    property string picking: ""

    // The default device of one side of the graph: its volume, its mute, and a
    // peak meter so a silent app is distinguishable from a wrong device.
    component DeviceRow: ColumnLayout {
        id: device

        required property var node
        required property string side
        required property var others

        readonly property bool active: device.node?.audio ? !device.node.audio.muted : false

        Layout.fillWidth: true
        spacing: 4

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            // Fixed width: volume glyphs differ, and the picker and its
            // choices line up on what follows.
            Text {
                Layout.preferredWidth: 16
                horizontalAlignment: Text.AlignHCenter
                text: device.side === "output" ? Audio.volumeGlyph(Math.round((device.node?.audio?.volume ?? 0) * 100), !device.active) : (device.active ? Config.glyph.mic : Config.glyph.micMuted)
                color: device.active ? Theme.orange : Theme.grey
                font.family: Theme.icon
                font.pixelSize: 15

                HoverHandler {

                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    onSingleTapped: Audio.toggleMute(device.node)
                }
            }

            // The device name unfolds the other devices of this side, when
            // there are any to pick.
            Rectangle {
                id: picker

                readonly property bool pickable: device.others.length > 1
                readonly property bool open: root.picking === device.side

                Layout.fillWidth: true
                implicitHeight: 22
                radius: 4
                color: picker.open ? Theme.alpha(Theme.fg, 0.1) : (picker.pickable && pickerHover.hovered ? Theme.alpha(Theme.fg, 0.06) : "transparent")

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    spacing: 8

                    Text {
                        Layout.fillWidth: true
                        text: Audio.label(device.node) || "None"
                        elide: Text.ElideRight
                        color: Theme.fg
                        font.family: Theme.ui
                        font.pixelSize: 12
                    }

                    Text {
                        text: `${Math.round((device.node?.audio?.volume ?? 0) * 100)}%`
                        color: Theme.alpha(Theme.fg, 0.6)
                        font.family: Theme.ui
                        font.pixelSize: 10
                    }
                }

                HoverHandler {
                    id: pickerHover

                    enabled: picker.pickable
                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    enabled: picker.pickable
                    onSingleTapped: root.picking = picker.open ? "" : device.side
                }
            }
        }

        // The other devices of this side, folded away until asked for.
        Repeater {
            model: root.picking === device.side ? device.others : []

            delegate: Rectangle {
                id: choice

                required property var modelData
                readonly property bool current: choice.modelData === device.node

                Layout.fillWidth: true
                Layout.leftMargin: 24
                implicitHeight: 22
                radius: 4
                color: hover.hovered ? Theme.alpha(Theme.fg, 0.06) : "transparent"

                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    text: (choice.current ? Config.glyph.check + " " : "") + Audio.label(choice.modelData)
                    elide: Text.ElideRight
                    color: choice.current ? Theme.orange : Theme.alpha(Theme.fg, 0.8)
                    font.family: Theme.ui
                    font.pixelSize: 11
                }

                HoverHandler {
                    id: hover

                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    onSingleTapped: {
                        if (device.side === "output")
                            Audio.setSink(choice.modelData);
                        else
                            Audio.setSource(choice.modelData);
                        root.picking = "";
                    }
                }
            }
        }

        Slider {
            Layout.fillWidth: true
            live: device.node !== null
            value: device.node?.audio?.volume ?? 0
            peak: meter.peak
            tint: device.active ? Theme.orange : Theme.grey
            onMoved: value => Audio.setVolume(device.node, value)
        }

        PwNodePeakMonitor {
            id: meter

            node: device.node
            // The meter is a pipewire stream of its own; it runs while the
            // panel is on screen and not a moment longer.
            enabled: root.visible && device.node !== null
        }
    }

    component StreamRow: ColumnLayout {
        id: stream

        required property var modelData
        readonly property var node: stream.modelData
        readonly property bool active: stream.node.audio ? !stream.node.audio.muted : false

        Layout.fillWidth: true
        spacing: 2

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                text: Audio.volumeGlyph(Math.round((stream.node.audio?.volume ?? 0) * 100), !stream.active)
                color: stream.active ? Theme.orange : Theme.grey
                font.family: Theme.icon
                font.pixelSize: 13

                HoverHandler {

                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    onSingleTapped: Audio.toggleMute(stream.node)
                }
            }

            Text {
                Layout.fillWidth: true
                text: Audio.appName(stream.node)
                elide: Text.ElideRight
                color: Theme.fg
                font.family: Theme.ui
                font.pixelSize: 11
            }

            Text {
                text: Audio.streamTitle(stream.node)
                Layout.maximumWidth: 140
                elide: Text.ElideRight
                color: Theme.alpha(Theme.fg, 0.45)
                font.family: Theme.ui
                font.pixelSize: 10
            }
        }

        Slider {
            Layout.fillWidth: true
            Layout.leftMargin: 21
            value: stream.node.audio?.volume ?? 0
            peak: meter.peak
            tint: stream.active ? Theme.orange : Theme.grey
            onMoved: value => Audio.setVolume(stream.node, value)
        }

        PwNodePeakMonitor {
            id: meter

            node: stream.node
            enabled: root.visible
        }
    }

    ColumnLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 8

        Text {
            Layout.fillWidth: true
            text: "Output"
            color: Theme.grey
            font.family: Theme.ui
            font.pixelSize: 12
        }

        DeviceRow {
            node: Audio.sink
            side: "output"
            others: Audio.sinks
        }

        Text {
            Layout.fillWidth: true
            Layout.topMargin: 4
            text: "Input"
            color: Theme.grey
            font.family: Theme.ui
            font.pixelSize: 12
        }

        DeviceRow {
            node: Audio.source
            side: "input"
            others: Audio.sources
        }

        Text {
            Layout.fillWidth: true
            Layout.topMargin: 4
            visible: Audio.streams.length > 0
            text: "Playing"
            color: Theme.grey
            font.family: Theme.ui
            font.pixelSize: 12
        }

        Repeater {
            model: Audio.streams
            delegate: StreamRow {}
        }

        Text {
            Layout.fillWidth: true
            visible: Audio.streams.length === 0
            text: "Nothing playing"
            color: Theme.alpha(Theme.fg, 0.45)
            font.family: Theme.ui
            font.pixelSize: 11
        }
    }
}

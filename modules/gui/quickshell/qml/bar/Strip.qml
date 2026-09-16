// Scale model of the active workspace's scrolling layout: one block per column,
// widths proportional to the real column widths, a frame marking the screenful
// that is on screen, and a scrim over what is scrolled off it. All geometry
// arrives in final pixels from niri-state.
import QtQuick
import Quickshell
import qs
import qs.components
import qs.services

Item {
    id: root

    required property string monitor

    readonly property var s: Niri.strip(monitor)
    readonly property int count: s ? s.count : 0
    // Pixels of a column that are off screen are shaded rather than cut away, so
    // a half-scrolled window stays one block. Only the gap between columns breaks
    // the strip.
    readonly property color scrim: Theme.alpha("#000000", 0.55)
    readonly property int bandHeight: 18

    visible: count > 0
    implicitWidth: (s ? s.w : 0) + 10
    implicitHeight: Theme.pillHeight

    Rectangle {
        anchors.fill: parent
        radius: Theme.pillRadius
        color: Theme.alpha("#000000", 0.25)
    }

    Item {
        id: inner
        anchors.centerIn: parent
        width: root.s ? root.s.w : 0
        height: parent.height

        // Filled bars, not a box with top and bottom borders: a bordered box also
        // paints its corner joins, which landed as a grey pixel inside the column
        // under each end of the rails.
        Repeater {
            model: [0, inner.height - 1]

            delegate: Rectangle {
                required property int modelData

                x: root.s ? root.s.frame.x : 0
                y: modelData
                width: root.s ? root.s.frame.w : 0
                height: 1
                color: Theme.alpha(Theme.fg, 0.85)
            }
        }

        Row {
            id: band
            y: (inner.height - root.bandHeight) / 2
            height: root.bandHeight
            spacing: 0

            Repeater {
                model: root.s ? root.s.columns : []

                delegate: Row {
                    id: column

                    required property var modelData
                    readonly property int tileHeight: (root.bandHeight - (modelData.tiles.length - 1)) / modelData.tiles.length

                    spacing: 0
                    height: root.bandHeight

                    Item {
                        width: column.modelData.pad
                        height: 1
                    }

                    Item {
                        id: block
                        width: column.modelData.w
                        height: root.bandHeight

                        Column {
                            anchors.fill: parent
                            spacing: 1

                            Repeater {
                                model: column.modelData.tiles

                                delegate: Item {
                                    required property var modelData

                                    width: block.width
                                    height: column.tileHeight

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 2
                                        color: {
                                            const state = column.modelData.state;
                                            if (state === "urgent")
                                                return Theme.red;
                                            const tint = state === "focused" ? Theme.orange : Theme.blue;
                                            return modelData.active ? tint : Theme.alpha(tint, 0.4);
                                        }
                                    }

                                    Rectangle {
                                        width: column.modelData.dim.left
                                        height: parent.height
                                        visible: width > 0
                                        color: root.scrim
                                        topLeftRadius: 2
                                        bottomLeftRadius: 2
                                    }

                                    Rectangle {
                                        x: parent.width - width
                                        width: column.modelData.dim.right
                                        height: parent.height
                                        visible: width > 0
                                        color: root.scrim
                                        topRightRadius: 2
                                        bottomRightRadius: 2
                                    }
                                }
                            }
                        }

                        // The app's own icon, resolved to a file by the emitter. Drawn
                        // as an image rather than a font glyph because a glyph's ink
                        // sits off-centre inside its advance box by an amount that
                        // differs per glyph, while a scaled image centres exactly.
                        Image {
                            anchors.centerIn: parent
                            source: column.modelData.icon !== "" ? "file://" + column.modelData.icon : ""
                            visible: column.modelData.icon !== ""
                            sourceSize.width: column.modelData.icon_px
                            sourceSize.height: column.modelData.icon_px
                            width: column.modelData.icon_px
                            height: column.modelData.icon_px
                            fillMode: Image.PreserveAspectFit
                        }

                        HoverHandler {
                            id: blockHover
                            cursorShape: Qt.PointingHandCursor
                        }

                        TapHandler {
                            acceptedButtons: Qt.LeftButton
                            onSingleTapped: Niri.focusColumn(column.modelData.idx)
                        }

                        TapHandler {
                            acceptedButtons: Qt.RightButton
                            onSingleTapped: Niri.toggleOverview()
                        }

                        Timer {
                            id: dwell
                            interval: 400
                            onTriggered: tip.active = true
                        }

                        Connections {
                            target: blockHover

                            function onHoveredChanged() {
                                if (blockHover.hovered) {
                                    dwell.restart();
                                } else {
                                    dwell.stop();
                                    tip.active = false;
                                }
                            }
                        }

                        LazyLoader {
                            id: tip

                            component: Component {
                                Tip {
                                    target: block
                                    text: column.modelData.tooltip
                                }
                            }
                        }
                    }
                }
            }
        }

        // Floating windows are drawn where niri actually puts them: they are the
        // only tiles whose position in the view the IPC reports.
        Row {
            y: band.y + 3
            spacing: 0

            Repeater {
                model: root.s ? root.s.floating : []

                delegate: Row {
                    required property var modelData

                    spacing: 0

                    Item {
                        width: modelData.pad
                        height: 1
                    }

                    Rectangle {
                        width: modelData.w
                        height: 3
                        radius: 2
                        color: Theme.purple
                    }
                }
            }
        }

        // A cropped strip fades into the bar rather than ending on a cut block.
        Repeater {
            model: [true, false]

            delegate: Rectangle {
                required property bool modelData

                x: modelData ? 0 : inner.width - width
                y: band.y
                width: 8
                height: root.bandHeight
                visible: root.s ? (modelData ? root.s.crop.left : root.s.crop.right) : false

                gradient: Gradient {
                    orientation: Gradient.Horizontal

                    GradientStop {
                        position: 0
                        color: modelData ? Theme.barBg : Theme.alpha(Theme.barBg, 0)
                    }

                    GradientStop {
                        position: 1
                        color: modelData ? Theme.alpha(Theme.barBg, 0) : Theme.barBg
                    }
                }
            }
        }
    }
}

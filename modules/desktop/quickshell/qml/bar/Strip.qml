// Scale model of the active workspace's scrolling layout: one block per column,
// widths proportional to the real column widths, a frame marking the screenful
// that is on screen, and a scrim over what is scrolled off it. All geometry
// arrives in final pixels from niri-state.
import QtQuick
import QtQuick.Effects
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
    // One physical pixel. The blocks' rounded corners are antialiased at
    // fractional scales, so the rails are too: a crisp rail snaps to the pixel
    // grid and ends half a pixel off the block beneath it.
    readonly property real hairline: 1 / (QsWindow.window ? QsWindow.window.devicePixelRatio : 1)
    readonly property color railColor: Theme.alpha(Theme.fg, 0.85)

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
        Rectangle {
            x: root.s ? root.s.frame.x : 0
            width: root.s ? root.s.frame.w : 0
            height: root.hairline
            antialiasing: true
            color: root.railColor
        }

        // Uncropped, the strip is the whole workspace and the bottom rail mirrors
        // the top one. Cropped, it becomes a minimap of the whole workspace with
        // the screen's place in it.
        Rectangle {
            readonly property var thumb: root.s ? root.s.thumb : null

            y: inner.height - root.hairline
            x: thumb ? 0 : (root.s ? root.s.frame.x : 0)
            width: thumb ? inner.width : (root.s ? root.s.frame.w : 0)
            height: root.hairline
            antialiasing: true
            color: thumb ? Theme.alpha(Theme.fg, 0.25) : root.railColor

            Rectangle {
                visible: parent.thumb !== null
                x: parent.thumb ? parent.thumb.x : 0
                width: parent.thumb ? parent.thumb.w : 0
                height: parent.height
                antialiasing: true
                color: root.railColor
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

                        readonly property int iconPx: column.modelData.icon_px
                        readonly property string mark: Config.appGlyph[column.modelData.app_id] ?? ""

                        width: column.modelData.w
                        height: root.bandHeight

                        Column {
                            anchors.fill: parent
                            spacing: 1

                            Repeater {
                                model: column.modelData.tiles

                                delegate: Item {
                                    required property var modelData

                                    // An end cut by the crop is drawn square: the
                                    // column goes on past it.
                                    readonly property int leftRadius: column.modelData.cut.left ? 0 : 2
                                    readonly property int rightRadius: column.modelData.cut.right ? 0 : 2

                                    width: block.width
                                    height: column.tileHeight

                                    Rectangle {
                                        anchors.fill: parent
                                        topLeftRadius: parent.leftRadius
                                        bottomLeftRadius: parent.leftRadius
                                        topRightRadius: parent.rightRadius
                                        bottomRightRadius: parent.rightRadius
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
                                        topLeftRadius: parent.leftRadius
                                        bottomLeftRadius: parent.leftRadius
                                    }

                                    Rectangle {
                                        x: parent.width - width
                                        width: column.modelData.dim.right
                                        height: parent.height
                                        visible: width > 0
                                        color: root.scrim
                                        topRightRadius: parent.rightRadius
                                        bottomRightRadius: parent.rightRadius
                                    }
                                }
                            }
                        }

                        // A monochrome glyph where the app has one, in the bar's ink.
                        Glyph {
                            anchors.centerIn: parent
                            visible: block.iconPx > 0 && block.mark !== ""
                            text: block.mark
                            color: Theme.ink
                            size: Math.min(Theme.fontSize, block.iconPx)
                        }

                        // Otherwise the app's own icon, greyed so it does not bring its
                        // colours into the bar. An image rather than a glyph centres
                        // exactly when scaled.
                        Image {
                            id: appIcon
                            anchors.centerIn: parent
                            source: block.mark === "" && column.modelData.icon !== "" ? "file://" + column.modelData.icon : ""
                            visible: false
                            sourceSize.width: block.iconPx
                            sourceSize.height: block.iconPx
                            width: block.iconPx
                            height: block.iconPx
                            fillMode: Image.PreserveAspectFit
                        }

                        MultiEffect {
                            anchors.fill: appIcon
                            source: appIcon
                            visible: block.iconPx > 0 && appIcon.source != ""
                            saturation: -1
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
    }
}

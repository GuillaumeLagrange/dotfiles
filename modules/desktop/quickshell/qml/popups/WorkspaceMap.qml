// The strip expanded: a workspace's columns at a readable scale, each tile
// showing its window as niri renders it, and the screenful on view outlined.
// Clicking a tile focuses that window.
import QtQuick
import Quickshell
import qs
import qs.components
import qs.services

PopupPanel {
    id: root

    // An entry of Niri.workspaces.
    required property var workspace

    readonly property var map: Niri.strip(workspace.name)?.map ?? null
    readonly property var columns: map ? map.columns : []
    // Height a screen-tall column is drawn at.
    readonly property int mapHeight: 200
    // Room around the tiles for the view's outline.
    readonly property int inset: 4
    readonly property real screenHeight: Math.max(1, ...columns.map(c => c.tiles.reduce((sum, t) => sum + t.h, 0)))
    readonly property real scale: mapHeight / screenHeight
    // A workspace narrower than the screen still has the screen outlined.
    readonly property real fullWidth: {
        const last = columns.length > 0 ? columns[columns.length - 1] : null;
        const end = Math.max(last ? last.x + last.w : 0, map ? map.view_x + map.view_w : 0);
        return end * scale + inset * 2;
    }
    readonly property real dpr: target.QsWindow.window ? target.QsWindow.window.devicePixelRatio : 1
    // Window id -> base64 PNG; "" while asked for or when niri had none.
    property var previews: ({})

    accent: workspace.is_focused ? Theme.orange : Theme.blue
    pad: 10

    onOpenChanged: {
        root.previews = {};
        if (root.open) {
            root.capture();
            Qt.callLater(root.centreView);
        }
    }
    onColumnsChanged: if (root.open)
        root.capture()

    // Asks niri for every tile not asked for since the panel opened, each at
    // the size it is drawn.
    function capture(): void {
        for (const column of root.columns) {
            for (const tile of column.tiles) {
                if (tile.id in root.previews)
                    continue;
                root.previews[tile.id] = "";
                const id = tile.id;
                const side = Math.ceil(Math.max(column.w, tile.h) * root.scale * root.dpr);
                Niri.windowPreview(id, side, b64 => {
                    if (!root.open)
                        return;
                    const next = Object.assign({}, root.previews);
                    next[id] = b64;
                    root.previews = next;
                });
            }
        }
    }

    function centreView(): void {
        if (!root.map)
            return;
        const centre = (root.map.view_x + root.map.view_w / 2) * root.scale + root.inset;
        flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, centre - flick.width / 2));
    }

    Item {
        // Wider than the screen allows, the map scrolls.
        implicitWidth: Math.min(root.fullWidth, (root.screen ? root.screen.width : 1920) - 2 * (root.pad + 40))
        implicitHeight: root.mapHeight + root.inset * 2

        Flickable {
            id: flick

            anchors.fill: parent
            clip: true
            contentWidth: root.fullWidth
            contentHeight: height
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds

            // A vertical wheel scrolls sideways: there is nothing to scroll up.
            WheelHandler {
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: event => {
                    const delta = event.angleDelta.x !== 0 ? event.angleDelta.x : event.angleDelta.y;
                    flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, flick.contentX - delta));
                }
            }

            Repeater {
                model: root.columns

                delegate: Column {
                    id: column

                    required property var modelData

                    x: root.inset + modelData.x * root.scale
                    y: root.inset
                    width: modelData.w * root.scale

                    Repeater {
                        model: column.modelData.tiles

                        delegate: Item {
                            id: tile

                            required property var modelData
                            readonly property string preview: root.previews[modelData.id] ?? ""
                            readonly property bool active: root.map !== null && root.map.active === modelData.id

                            width: column.width
                            height: modelData.h * root.scale

                            Rectangle {
                                id: face

                                anchors.fill: parent
                                anchors.margins: 1
                                radius: 4
                                color: Theme.well
                            }

                            Image {
                                id: shot

                                anchors.fill: face
                                source: tile.preview !== "" ? "data:image/png;base64," + tile.preview : ""
                                cache: false
                                fillMode: Image.PreserveAspectCrop
                            }

                            // Until niri's render arrives, or when it has none.
                            Image {
                                anchors.centerIn: face
                                visible: shot.status !== Image.Ready && source != ""
                                source: tile.modelData.icon !== "" ? "file://" + tile.modelData.icon : ""
                                sourceSize.width: 32
                                sourceSize.height: 32
                                width: 32
                                height: 32
                            }

                            // The window's icon and title, along the bottom.
                            Rectangle {
                                anchors.left: face.left
                                anchors.right: face.right
                                anchors.bottom: face.bottom
                                height: 22
                                bottomLeftRadius: face.radius
                                bottomRightRadius: face.radius
                                color: Theme.alpha("#000000", 0.7)

                                Row {
                                    anchors.fill: parent
                                    anchors.leftMargin: 5
                                    anchors.rightMargin: 5
                                    spacing: 5

                                    Image {
                                        id: captionIcon

                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: source != ""
                                        source: tile.modelData.icon !== "" ? "file://" + tile.modelData.icon : ""
                                        sourceSize.width: 14
                                        sourceSize.height: 14
                                        width: 14
                                        height: 14
                                    }

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - (captionIcon.visible ? captionIcon.width + parent.spacing : 0)
                                        text: Niri.windowTitles[tile.modelData.id] || tile.modelData.app
                                        elide: Text.ElideRight
                                        color: Theme.fg
                                        font.family: Theme.ui
                                        font.pixelSize: 11
                                        textFormat: Text.PlainText
                                    }
                                }
                            }

                            Rectangle {
                                anchors.fill: face
                                radius: face.radius
                                color: tileHover.hovered ? Theme.hoverFill : "transparent"
                                border.width: tile.active || tileHover.hovered ? 2 : 1
                                border.color: tile.active ? root.accent : tileHover.hovered ? Theme.fg : Theme.border
                            }

                            HoverHandler {
                                id: tileHover
                                cursorShape: Qt.PointingHandCursor
                            }

                            TapHandler {
                                onSingleTapped: {
                                    Niri.focusWindow(tile.modelData.id);
                                    root.close();
                                }
                            }
                        }
                    }
                }
            }

            // The screenful on view.
            Rectangle {
                visible: root.map !== null
                x: root.map ? root.map.view_x * root.scale + root.inset / 2 : 0
                width: root.map ? root.map.view_w * root.scale + root.inset : 0
                height: flick.height
                radius: 6
                color: "transparent"
                border.width: 1
                border.color: Theme.alpha(Theme.fg, 0.85)
            }
        }
    }
}

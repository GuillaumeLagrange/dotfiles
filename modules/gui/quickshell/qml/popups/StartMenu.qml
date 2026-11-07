// The start menu: pinned apps in a grid, every app below them. A click
// launches an app, a right click pins or unpins it, and dragging a pinned tile
// moves it. Typing filters the apps, the arrows move the cursor and Enter
// launches what it is on.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs
import qs.components
import qs.services

ClickPanel {
    id: root

    readonly property int columns: 6
    readonly property int cellWidth: 76
    readonly property int cellHeight: 74

    accent: Theme.blue
    panelWidth: root.columns * root.cellWidth + root.pad * 2

    readonly property var apps: DesktopEntries.applications.values.filter(e => !e.noDisplay).sort((a, b) => a.name.localeCompare(b.name))
    // Pins of apps no longer installed stay in the file, in case they come back.
    readonly property var pins: StartPins.ids.map(id => root.apps.find(e => e.id === id)).filter(e => e !== undefined)

    readonly property bool filtering: find.query !== ""
    readonly property var rows: root.filtering ? find.filter(root.apps, e => e.name) : root.apps
    // What the cursor walks: the tiles then the rows, or the matches alone.
    readonly property var choices: root.filtering ? root.rows : root.pins.concat(root.rows)
    readonly property int tileCount: root.filtering ? 0 : root.pins.length
    property int cursor: -1

    // The pin being dragged, and the order the others make room for meanwhile.
    property string dragId: ""
    property var dragOrder: []

    function iconFor(entry: var): string {
        if (entry.icon.startsWith("/"))
            return "file://" + entry.icon;
        return Quickshell.iconPath(entry.icon, "application-x-executable");
    }

    function launch(entry: var): void {
        root.close();
        let command = Array.from(entry.command);
        if (entry.runInTerminal)
            command = Config.termExec.concat(command);
        if (entry.workingDirectory !== "")
            command = Config.chdir.concat([entry.workingDirectory], command);
        Quickshell.execDetached(Config.launch.concat(command));
    }

    function launchCursor(): void {
        const entry = root.choices[root.cursor];
        if (entry)
            root.launch(entry);
    }

    // Up and Down move by a row of tiles inside the grid, and cross between it and the list.
    function step(key: int): void {
        const n = root.choices.length;
        if (n === 0)
            return;
        const tiles = root.tileCount;
        const at = root.cursor;
        let next = at;
        if (at < 0)
            next = 0;
        else if (key === Qt.Key_Left)
            next = at - 1;
        else if (key === Qt.Key_Right)
            next = at + 1;
        else if (key === Qt.Key_Up)
            next = at < tiles ? (at >= root.columns ? at - root.columns : at) : at === tiles ? Math.floor((tiles - 1) / root.columns) * root.columns : at - 1;
        else if (key === Qt.Key_Down)
            next = at < tiles ? (at + root.columns < tiles ? at + root.columns : Math.floor(at / root.columns) === Math.floor((tiles - 1) / root.columns) ? tiles : tiles - 1) : at + 1;
        root.cursor = Math.max(0, Math.min(n - 1, next));
        if (root.cursor >= tiles)
            list.positionViewAtIndex(root.cursor - tiles, ListView.Contain);
    }

    // Moves the dragged pin to the cell under the tile's centre.
    function retarget(cx: real, cy: real): void {
        const rows = Math.ceil(root.dragOrder.length / root.columns);
        const col = Math.max(0, Math.min(root.columns - 1, Math.floor(cx / root.cellWidth)));
        const row = Math.max(0, Math.min(rows - 1, Math.floor(cy / root.cellHeight)));
        const target = Math.min(row * root.columns + col, root.dragOrder.length - 1);
        if (root.dragOrder.indexOf(root.dragId) === target)
            return;
        const order = root.dragOrder.filter(id => id !== root.dragId);
        order.splice(target, 0, root.dragId);
        root.dragOrder = order;
    }

    onShown: {
        root.cursor = -1;
        list.positionViewAtBeginning();
        list.forceActiveFocus();
    }
    onHidden: {
        find.query = "";
        root.dragId = "";
    }

    ColumnLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 10

        PanelTitle {
            glyph: Config.glyph.apps
            text: "Apps"
            accent: root.accent

            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: !root.filtering
                text: "type to search"
                color: Theme.faint
                font.family: Theme.ui
                font.pixelSize: 10
            }
        }

        FindBar {
            id: find

            accent: root.accent
            empty: root.rows.length === 0
            onQueryChanged: {
                root.cursor = root.filtering && root.rows.length > 0 ? 0 : -1;
                list.positionViewAtBeginning();
            }
        }

        SectionLabel {
            visible: !root.filtering
            text: "Pinned"
        }

        Rectangle {
            Layout.fillWidth: true
            visible: !root.filtering && root.pins.length === 0
            implicitHeight: 44
            radius: Theme.rowRadius
            color: Theme.well

            Text {
                anchors.centerIn: parent
                text: "Right-click an app to pin it here"
                color: Theme.faint
                font.family: Theme.ui
                font.pixelSize: 11
            }
        }

        Item {
            id: grid

            visible: root.tileCount > 0
            implicitWidth: root.columns * root.cellWidth
            implicitHeight: Math.ceil(root.pins.length / root.columns) * root.cellHeight

            Repeater {
                model: root.pins

                Item {
                    id: tile

                    required property var modelData
                    required property int index
                    readonly property bool held: root.dragId === tile.modelData.id
                    readonly property int slot: root.dragId !== "" ? root.dragOrder.indexOf(tile.modelData.id) : tile.index
                    readonly property bool current: root.cursor === tile.index
                    property real grabX: 0
                    property real grabY: 0

                    width: root.cellWidth
                    height: root.cellHeight
                    x: tile.held ? tile.grabX + drag.activeTranslation.x : (tile.slot % root.columns) * root.cellWidth
                    y: tile.held ? tile.grabY + drag.activeTranslation.y : Math.floor(tile.slot / root.columns) * root.cellHeight
                    z: tile.held ? 1 : 0

                    Behavior on x {
                        enabled: !tile.held

                        NumberAnimation {
                            duration: 120
                            easing.type: Easing.OutCubic
                        }
                    }

                    Behavior on y {
                        enabled: !tile.held

                        NumberAnimation {
                            duration: 120
                            easing.type: Easing.OutCubic
                        }
                    }

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 2
                        radius: Theme.rowRadius
                        color: tile.held || tileHover.hovered || tile.current ? Theme.hoverFill : "transparent"
                        border.width: tile.current ? 1 : 0
                        border.color: Theme.alpha(root.accent, 0.6)
                    }

                    IconImage {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 10
                        source: root.iconFor(tile.modelData)
                        implicitSize: 32
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: 6
                        y: 48
                        text: tile.modelData.name
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        color: Theme.fg
                        font.family: Theme.ui
                        font.pixelSize: 10
                    }

                    HoverHandler {
                        id: tileHover

                        cursorShape: tile.held ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                    }

                    TapHandler {
                        acceptedButtons: Qt.LeftButton
                        onSingleTapped: root.launch(tile.modelData)
                    }

                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        onSingleTapped: StartPins.toggle(tile.modelData.id)
                    }

                    DragHandler {
                        id: drag

                        target: null
                        onActiveChanged: {
                            if (drag.active) {
                                tile.grabX = tile.x;
                                tile.grabY = tile.y;
                                root.dragOrder = root.pins.map(e => e.id);
                                root.dragId = tile.modelData.id;
                            } else if (tile.held) {
                                const order = root.dragOrder;
                                root.dragId = "";
                                StartPins.save(order);
                            }
                        }
                        onActiveTranslationChanged: if (tile.held)
                            root.retarget(tile.x + tile.width / 2, tile.y + tile.height / 2)
                    }
                }
            }
        }

        SectionLabel {
            visible: !root.filtering
            text: "All apps"
        }

        ListView {
            id: list

            Layout.fillWidth: true
            // As tall as its rows, up to what the output leaves above the pins.
            Layout.preferredHeight: Math.min(list.contentHeight, Math.max(160, Math.min(360, (root.screen?.height ?? 1000) - 260 - grid.implicitHeight)))
            clip: true
            spacing: 2
            model: root.rows
            keyNavigationEnabled: false
            Keys.onLeftPressed: root.step(Qt.Key_Left)
            Keys.onRightPressed: root.step(Qt.Key_Right)
            Keys.onUpPressed: root.step(Qt.Key_Up)
            Keys.onDownPressed: root.step(Qt.Key_Down)
            Keys.onReturnPressed: root.launchCursor()
            Keys.onEnterPressed: root.launchCursor()
            Keys.onEscapePressed: event => {
                if (find.query !== "")
                    find.query = "";
                else
                    event.accepted = false;
            }
            Keys.onPressed: event => {
                event.accepted = find.type(event);
            }

            ScrollBar.vertical: ScrollBar {
                id: vbar

                policy: list.contentHeight > list.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                implicitWidth: 8
                padding: 2
                background: null

                contentItem: Rectangle {
                    radius: width / 2
                    color: Theme.alpha(Theme.fg, vbar.pressed ? 0.5 : vbar.hovered ? 0.35 : 0.2)
                }
            }

            delegate: Rectangle {
                id: row

                required property var modelData
                required property int index
                readonly property bool current: root.cursor === root.tileCount + row.index
                readonly property bool pinned: StartPins.ids.includes(row.modelData.id)

                width: list.width - (vbar.visible ? vbar.implicitWidth + 2 : 0)
                implicitHeight: 30
                radius: Theme.rowRadius
                color: rowHover.hovered || row.current ? Theme.hoverFill : "transparent"
                border.width: row.current ? 1 : 0
                border.color: Theme.alpha(root.accent, 0.6)

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    spacing: 10

                    IconImage {
                        source: root.iconFor(row.modelData)
                        implicitSize: 20
                    }

                    Text {
                        text: row.modelData.name
                        color: Theme.fg
                        font.family: Theme.ui
                        font.pixelSize: 12
                    }

                    Text {
                        Layout.fillWidth: true
                        text: row.modelData.genericName !== row.modelData.name ? row.modelData.genericName : ""
                        elide: Text.ElideRight
                        color: Theme.faint
                        font.family: Theme.ui
                        font.pixelSize: 11
                    }

                    Glyph {
                        visible: row.pinned
                        text: Config.glyph.pin
                        color: Theme.soften(root.accent)
                        size: 12
                    }
                }

                HoverHandler {
                    id: rowHover

                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    onSingleTapped: root.launch(row.modelData)
                }

                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onSingleTapped: StartPins.toggle(row.modelData.id)
                }
            }
        }
    }
}

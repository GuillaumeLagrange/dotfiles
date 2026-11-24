// The launcher: a search box over the daemon's rows, centred on the focused
// output. Everything it lists and does comes from `services/Launcher.qml`;
// this draws it and turns keys into its calls. One window for the shell, put
// on the output the panel opened on.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import qs
import qs.components
import qs.services as Svc

PanelWindow {
    id: root

    readonly property var svc: Svc.Launcher
    readonly property var accents: ({
            apps: Theme.blue,
            windows: Theme.aqua,
            emoji: Theme.yellow,
            clipboard: Theme.purple,
            browser: Theme.orange,
            passwords: Theme.green,
            sessions: Theme.aqua,
            reviews: Theme.green,
            files: Theme.yellow,
            power: Theme.purple
        })
    readonly property color accent: root.accents[root.svc.mode] ?? Theme.blue
    readonly property color mark: Theme.soften(root.accent)
    readonly property bool hasPreview: root.svc.items.some(i => i.preview)
    readonly property int rowHeight: 44
    readonly property int visibleRows: 9

    property bool menuOpen: false
    property int menuCursor: 0
    readonly property var menuActions: {
        const actions = root.svc.current?.actions ?? [];
        const q = menuField.text.toLowerCase();
        return q === "" ? actions : actions.filter(a => a.label.toLowerCase().includes(q));
    }

    // The rows' list while the panel is open.
    property ListView list: null

    // Read by the test probe.
    readonly property bool focused: (field.activeFocus || menuField.activeFocus) && field.Window.active
    readonly property var probeList: root.list
    readonly property bool probeLoading: sweepTrack.shown
    readonly property string probeStatusLine: statusLine.message

    function htmlEscape(s: string): string {
        return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    // `text` with its UTF-16 `ranges` bold in the accent, the rest escaped.
    function marked(text: string, ranges: var): string {
        let out = "";
        let at = 0;
        for (const r of (ranges ?? []).slice().sort((a, b) => a[0] - b[0])) {
            if (r[0] < at)
                continue;
            out += root.htmlEscape(text.slice(at, r[0])) + `<b><font color="${root.mark}">` + root.htmlEscape(text.slice(r[0], r[1])) + "</font></b>";
            at = r[1];
        }
        return out + root.htmlEscape(text.slice(at));
    }

    function keyLabel(key: string): string {
        return {
            "Return": "\u21b5",
            "Alt+Return": "Alt \u21b5",
            "Ctrl+Return": "Ctrl \u21b5",
            "Shift+Delete": "Shift Del",
            "Ctrl+R": "Ctrl R"
        }[key] ?? key;
    }

    function keyName(event: var): string {
        const mods = event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier);
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
            return mods === Qt.AltModifier ? "Alt+Return" : mods === Qt.ControlModifier ? "Ctrl+Return" : mods === 0 ? "Return" : "";
        if (event.key === Qt.Key_Delete && mods === Qt.ShiftModifier)
            return "Shift+Delete";
        if (event.key === Qt.Key_R && mods === Qt.ControlModifier)
            return "Ctrl+R";
        return "";
    }

    function openMenu(): void {
        if (!root.svc.current || (root.svc.current.actions ?? []).length === 0)
            return;
        menuField.text = "";
        root.menuCursor = 0;
        root.menuOpen = true;
        menuField.forceActiveFocus();
    }

    function closeMenu(): void {
        root.menuOpen = false;
        field.forceActiveFocus();
    }

    function runMenu(): void {
        const action = root.menuActions[root.menuCursor];
        const item = root.svc.current;
        root.closeMenu();
        if (action && item)
            root.svc.activate(item.id, action.id);
    }

    function iconSource(icon: var): string {
        if (!icon)
            return "";
        if (icon.kind === "name")
            return Quickshell.iconPath(icon.value, "application-x-executable");
        if (icon.kind === "path")
            return "file://" + icon.value;
        if (icon.kind === "url")
            return icon.value;
        return "";
    }

    screen: Quickshell.screens.find(s => s.name === root.svc.output) ?? Quickshell.screens[0] ?? null
    visible: root.svc.open
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "launcher"
    WlrLayershell.keyboardFocus: root.svc.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    onVisibleChanged: {
        root.menuOpen = false;
        if (root.visible) {
            field.text = "";
            field.forceActiveFocus();
        }
    }

    // Brings the cursor's row into view, the list's start when it is the first row. Called
    // once the list has the new rows: a query keeping some rows and ranking new ones above
    // them leaves the kept rows where they were, the new ones above the viewport.
    function reveal(): void {
        const at = root.svc.cursorIndex;
        if (!root.list)
            return;
        if (at <= 0)
            root.list.positionViewAtBeginning();
        else
            root.list.positionViewAtIndex(at, ListView.Contain);
    }

    Connections {
        target: root.svc

        function onQueryChanged(): void {
            if (field.text !== root.svc.query)
                field.text = root.svc.query;
        }

        function onCursorChanged(): void {
            Qt.callLater(root.reveal);
            previewDwell.restart();
        }

        function onItemsChanged(): void {
            Qt.callLater(root.reveal);
        }

        function onModeChanged(): void {
            root.menuOpen = false;
        }
    }

    // A preview is asked for once the cursor rests on its row.
    Timer {
        id: previewDwell

        interval: 80
        onTriggered: root.svc.requestPreview()
    }

    IpcHandler {
        target: "launcher"

        function open(mode: string): void {
            root.svc.show(mode);
        }

        function toggle(mode: string): void {
            root.svc.toggle(mode);
        }

        function close(): void {
            root.svc.hide();
        }
    }

    MouseArea {
        anchors.fill: parent
        onPressed: root.svc.hide()
    }

    Rectangle {
        id: panel

        width: Math.min(root.hasPreview ? 900 : 720, root.width - 40)
        height: search.height + 1 + listArea.height + footer.height
        x: Math.round((root.width - panel.width) / 2)
        y: Math.round(root.height * 0.2)
        radius: Theme.panelRadius
        color: Theme.drawerBg
        border.color: Theme.border
        border.width: 1

        // Swallows clicks, so only the backdrop's close the panel.
        MouseArea {
            anchors.fill: parent
        }

        Item {
            id: search

            width: parent.width
            height: 56

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 16
                spacing: 12

                Rectangle {
                    id: chip

                    implicitWidth: chipRow.implicitWidth + 16
                    implicitHeight: 26
                    radius: Theme.pillRadius
                    color: Theme.alpha(root.accent, 0.16)
                    border.width: 1
                    border.color: Theme.alpha(root.accent, 0.45)

                    Row {
                        id: chipRow

                        anchors.centerIn: parent
                        spacing: 6

                        Glyph {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 14
                            height: 14
                            text: Config.glyph[root.svc.modeInfo.glyph] ?? Config.glyph.apps
                            color: root.mark
                            size: 14
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.svc.modeInfo.title
                            color: root.mark
                            font.family: Theme.ui
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                        }
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: field.text === ""
                        text: `Search ${root.svc.modeInfo.title.toLowerCase()}\u2026   / for modes`
                        color: Theme.faint
                        font.family: Theme.ui
                        font.pixelSize: 16
                    }

                    TextInput {
                        id: field

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        color: Theme.fg
                        selectionColor: Theme.alpha(root.accent, 0.4)
                        selectedTextColor: Theme.fg
                        cursorDelegate: Rectangle {
                            width: 2
                            color: root.accent
                            visible: field.cursorVisible
                        }
                        font.family: Theme.ui
                        font.pixelSize: 16
                        clip: true

                        onTextChanged: root.svc.setQuery(field.text)

                        Keys.onPressed: event => {
                            const ctrl = event.modifiers & Qt.ControlModifier;
                            const key = root.keyName(event);
                            // An activation runs on: only Escape, which leaves it to finish alone.
                            if (root.svc.working !== "") {
                                if (event.key === Qt.Key_Escape)
                                    root.svc.hide();
                                event.accepted = true;
                            } else if (key !== "") {
                                event.accepted = root.svc.activateKey(key);
                            } else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_N)) {
                                root.svc.step(1);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_P)) {
                                root.svc.step(-1);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_PageDown) {
                                root.svc.step(root.visibleRows - 1);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_PageUp) {
                                root.svc.step(1 - root.visibleRows);
                                event.accepted = true;
                            } else if (ctrl && event.key === Qt.Key_K) {
                                root.openMenu();
                                event.accepted = true;
                            } else if (ctrl && event.key === Qt.Key_U) {
                                field.text = "";
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Tab) {
                                root.svc.cycle(1);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Backtab) {
                                root.svc.cycle(-1);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Escape) {
                                root.svc.hide();
                                event.accepted = true;
                            }
                        }
                    }
                }

                Text {
                    visible: root.svc.total > 0
                    text: root.svc.total === root.svc.items.length ? `${root.svc.total}` : `${root.svc.items.length} of ${root.svc.total}`
                    color: Theme.faint
                    font.family: Theme.ui
                    font.pixelSize: 11
                    font.features: {
                        "tnum": 1
                    }
                }
            }

            // Loading: a thin bar of the accent sweeping along the bottom edge, clipped to the
            // panel since it slides in from beyond it. Shown once loading lasts: a mode switch
            // answers within milliseconds, and a bar flashing on every Tab is noise.
            Item {
                id: sweepTrack

                readonly property bool loading: root.svc.busy || root.svc.working !== "" || root.svc.status?.kind === "loading"
                property bool shown: false

                y: parent.height - 1
                width: parent.width
                height: 1
                clip: true
                visible: sweepTrack.shown

                onLoadingChanged: {
                    if (sweepTrack.loading) {
                        sweepDelay.restart();
                    } else {
                        sweepDelay.stop();
                        sweepTrack.shown = false;
                    }
                }

                Timer {
                    id: sweepDelay

                    interval: 150
                    onTriggered: sweepTrack.shown = sweepTrack.loading
                }

                Rectangle {
                    id: sweep

                    width: sweepTrack.width * 0.25
                    height: 1
                    color: root.accent

                    NumberAnimation on x {
                        running: sweepTrack.visible
                        loops: Animation.Infinite
                        from: -sweep.width
                        to: sweepTrack.width
                        duration: 900
                    }
                }
            }
        }

        Rectangle {
            y: search.height
            width: parent.width
            height: 1
            color: Theme.border
        }

        Item {
            id: listArea

            y: search.height + 1
            width: parent.width
            height: root.visibleRows * root.rowHeight + 16

            readonly property real listWidth: (root.hasPreview ? width * 0.5 : width) - 16

            // A list per opened mode, dropped when the panel closes or switches mode: Qt 6.12's
            // ListView has left delegates of replaced rows drawn over the new ones, for good,
            // and destroying the list destroys them.
            Repeater {
                model: root.svc.open ? [root.svc.mode] : []
                onItemAdded: (index, item) => root.list = item
                onItemRemoved: (index, item) => {
                    if (root.list === item)
                        root.list = null;
                }

                ListView {
                    id: list

                    x: 8
                    y: 8
                    width: listArea.listWidth
                    height: parent.height - 16
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    highlightMoveDuration: 0
                    // A plain array: each results resets the list. A ScriptModel's inserts and
                    // removes left removed rows drawn over the new ones (Qt 6.12), and its
                    // structural matching crashes the bar (quickshell#1369).
                    model: root.svc.items

                    ScrollBar.vertical: ScrollBar {
                        id: vbar

                        policy: list.contentHeight > list.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                        implicitWidth: 6
                        padding: 1
                        background: null

                        contentItem: Rectangle {
                            radius: width / 2
                            color: Theme.alpha(Theme.fg, vbar.pressed ? 0.4 : 0.18)
                        }
                    }

                    delegate: Item {
                        id: row

                        required property var modelData
                        required property int index
                        readonly property bool current: root.svc.cursor === row.modelData.id
                        readonly property bool heading: row.modelData.section && row.modelData.section !== "" && (row.index === 0 || root.svc.items[row.index - 1]?.section !== row.modelData.section)
                        readonly property var icon: row.modelData.icon ?? {
                            kind: "none"
                        }

                        width: list.width - (vbar.visible ? 8 : 0)
                        height: root.rowHeight + (row.heading ? 26 : 0)

                        Text {
                            visible: row.heading
                            x: 10
                            y: 8
                            text: row.modelData.section ?? ""
                            color: Theme.dim
                            font.family: Theme.ui
                            font.pixelSize: 10
                            font.weight: Font.DemiBold
                            font.letterSpacing: 0.8
                            font.capitalization: Font.AllUppercase
                        }

                        Rectangle {
                            id: body

                            y: row.heading ? 26 : 0
                            width: parent.width
                            height: root.rowHeight
                            radius: Theme.rowRadius
                            // The cursor outlined in the accent, as the bar's other keyboard lists mark
                            // theirs, over a stronger tint than hover's.
                            color: row.current ? Theme.alpha(root.accent, 0.2) : rowHover.hovered ? Theme.hoverFill : "transparent"
                            border.width: row.current ? 1 : 0
                            border.color: Theme.alpha(root.accent, 0.6)

                            Rectangle {
                                visible: row.current
                                x: 0
                                anchors.verticalCenter: parent.verticalCenter
                                width: 3
                                height: 20
                                radius: 1.5
                                color: root.accent
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 12

                                Item {
                                    implicitWidth: 28
                                    implicitHeight: 28

                                    IconImage {
                                        anchors.fill: parent
                                        visible: ["name", "path", "url"].includes(row.icon.kind)
                                        source: visible ? root.iconSource(row.icon) : ""
                                        implicitSize: 28
                                        asynchronous: true
                                    }

                                    Text {
                                        anchors.centerIn: parent
                                        visible: row.icon.kind === "emoji"
                                        text: visible ? row.icon.value : ""
                                        font.pixelSize: 22
                                    }

                                    Rectangle {
                                        anchors.fill: parent
                                        visible: row.icon.kind === "glyph" || row.icon.kind === "none"
                                        radius: Theme.rowRadius
                                        color: Theme.well

                                        Glyph {
                                            anchors.centerIn: parent
                                            width: 16
                                            height: 16
                                            text: row.icon.kind === "glyph" ? (Config.glyph[row.icon.value] ?? "") : (Config.glyph[root.svc.modeInfo.glyph] ?? "")
                                            color: row.current ? root.mark : Theme.dim
                                            size: 16
                                        }
                                    }
                                }

                                Rectangle {
                                    visible: !!row.modelData.color
                                    implicitWidth: 8
                                    implicitHeight: 8
                                    radius: 4
                                    color: row.modelData.color || "transparent"
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 1

                                    Text {
                                        Layout.fillWidth: true
                                        text: root.marked(row.modelData.title ?? "", row.modelData.hl)
                                        textFormat: Text.StyledText
                                        elide: Text.ElideRight
                                        color: Theme.fg
                                        font.family: Theme.ui
                                        font.pixelSize: 13
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        visible: (row.modelData.subtitle ?? "") !== ""
                                        text: root.marked(row.modelData.subtitle ?? "", row.modelData.shl)
                                        textFormat: Text.StyledText
                                        elide: Text.ElideRight
                                        color: Theme.dim
                                        font.family: Theme.ui
                                        font.pixelSize: 11
                                    }
                                }

                                Text {
                                    visible: (row.modelData.accessory ?? "") !== ""
                                    Layout.maximumWidth: 180
                                    text: row.modelData.accessory ?? ""
                                    elide: Text.ElideLeft
                                    color: Theme.faint
                                    font.family: Theme.ui
                                    font.pixelSize: 11
                                    font.features: {
                                        "tnum": 1
                                    }
                                }
                            }

                            HoverHandler {
                                id: rowHover

                                cursorShape: Qt.PointingHandCursor
                            }

                            TapHandler {
                                onSingleTapped: root.svc.select(row.modelData.id)
                                onDoubleTapped: {
                                    root.svc.select(row.modelData.id);
                                    root.svc.activateKey("Return");
                                }
                            }
                        }
                    }
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.horizontalCenter: parent.left
                anchors.horizontalCenterOffset: 8 + listArea.listWidth / 2
                visible: root.svc.items.length === 0 && !root.svc.busy
                text: root.svc.connected ? "No results" : ""
                color: Theme.faint
                font.family: Theme.ui
                font.pixelSize: 13
            }

            // The preview of the row under the cursor.
            Rectangle {
                id: previewPane

                readonly property var p: root.svc.preview

                visible: root.hasPreview
                x: listArea.listWidth + 16
                y: 8
                width: parent.width - x - 8
                height: parent.height - 16
                radius: Theme.rowRadius
                color: Theme.well
                clip: true

                Text {
                    anchors.centerIn: parent
                    visible: previewPane.p === null
                    text: root.svc.current?.preview ? "\u2026" : "No preview"
                    color: Theme.faint
                    font.family: Theme.ui
                    font.pixelSize: 12
                }

                Flickable {
                    anchors.fill: parent
                    anchors.margins: 12
                    visible: previewPane.p?.kind === "text"
                    contentHeight: previewText.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true

                    Text {
                        id: previewText

                        width: parent.width
                        text: previewPane.p?.kind === "text" ? previewPane.p.text : ""
                        textFormat: Text.PlainText
                        wrapMode: Text.WrapAnywhere
                        color: Theme.fg
                        font.family: previewPane.p?.mono ? Theme.mono : Theme.ui
                        font.pixelSize: previewPane.p?.mono ? 11 : 12
                        lineHeight: 1.15
                    }
                }

                Image {
                    anchors.fill: parent
                    anchors.margins: 12
                    visible: previewPane.p?.kind === "image"
                    source: visible ? "file://" + previewPane.p.path : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    smooth: true
                    mipmap: true
                }

                Column {
                    anchors.fill: parent
                    anchors.margins: 14
                    visible: previewPane.p?.kind === "fields"
                    spacing: 10

                    Repeater {
                        model: previewPane.p?.kind === "fields" ? previewPane.p.fields : []

                        Column {
                            required property var modelData

                            width: parent.width
                            spacing: 2

                            SectionLabel {
                                text: modelData[0]
                            }

                            Text {
                                width: parent.width
                                text: modelData[1]
                                wrapMode: Text.WrapAnywhere
                                color: Theme.fg
                                font.family: Theme.ui
                                font.pixelSize: 12
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            id: footer

            y: listArea.y + listArea.height
            width: parent.width
            height: 34
            color: Theme.alpha("#000000", 0.18)
            bottomLeftRadius: Theme.panelRadius
            bottomRightRadius: Theme.panelRadius

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.border
            }

            // The status line: an error first, then the work an activation waits for, then the
            // daemon's status.
            RowLayout {
                id: statusLine

                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width * 0.5
                spacing: 6

                readonly property string kind: root.svc.error !== "" ? "error" : !root.svc.connected || root.svc.working !== "" ? "loading" : root.svc.status?.kind ?? ""
                readonly property string message: root.svc.error !== "" ? root.svc.error : !root.svc.connected ? "Connecting to the launcher\u2026" : root.svc.working !== "" ? root.svc.working : root.svc.status?.text ?? ""

                Glyph {
                    id: statusGlyph

                    visible: parent.kind !== ""
                    width: 12
                    height: 12
                    text: parent.kind === "error" ? Config.glyph.alert : parent.kind === "loading" ? Config.glyph.loading : Config.glyph.info
                    color: parent.kind === "error" ? Theme.red : Theme.dim
                    size: 12

                    RotationAnimator on rotation {
                        running: statusGlyph.visible && statusGlyph.text === Config.glyph.loading
                        loops: Animation.Infinite
                        from: 0
                        to: 360
                        duration: 1000
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: parent.message
                    elide: Text.ElideRight
                    color: parent.kind === "error" ? Theme.red : Theme.dim
                    font.family: Theme.ui
                    font.pixelSize: 11
                }
            }

            Row {
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 14

                Repeater {
                    model: (root.svc.current?.actions ?? []).filter(a => a.key).slice(0, 3).concat((root.svc.current?.actions ?? []).length > 0 ? [
                        {
                            label: "Actions",
                            key: "Ctrl+K"
                        }
                    ] : [])

                    Row {
                        required property var modelData
                        required property int index

                        spacing: 6

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.label
                            color: index === 0 ? Theme.fg : Theme.dim
                            font.family: Theme.ui
                            font.pixelSize: 11
                        }

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            implicitWidth: keyText.implicitWidth + 10
                            implicitHeight: 18
                            radius: 4
                            color: Theme.alpha(Theme.fg, 0.08)

                            Text {
                                id: keyText

                                anchors.centerIn: parent
                                text: modelData.key === "Ctrl+K" ? "Ctrl K" : root.keyLabel(modelData.key)
                                color: Theme.dim
                                font.family: Theme.ui
                                font.pixelSize: 10
                                font.weight: Font.DemiBold
                            }
                        }
                    }
                }
            }
        }

        // Ctrl+K: the current row's actions, filterable.
        Rectangle {
            id: menu

            visible: root.menuOpen
            width: 300
            height: menuColumn.implicitHeight + 12
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.bottom: footer.top
            anchors.bottomMargin: 8
            radius: Theme.panelRadius
            color: Qt.lighter(Theme.drawerBg, 1.25)
            border.color: Theme.alpha(Theme.fg, 0.14)
            border.width: 1

            Column {
                id: menuColumn

                x: 6
                y: 6
                width: parent.width - 12
                spacing: 2

                Repeater {
                    model: root.menuActions

                    Rectangle {
                        required property var modelData
                        required property int index

                        width: menuColumn.width
                        height: 30
                        radius: Theme.rowRadius
                        color: index === root.menuCursor ? Theme.alpha(root.accent, 0.18) : actionHover.hovered ? Theme.hoverFill : "transparent"

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.label
                            color: Theme.fg
                            font.family: Theme.ui
                            font.pixelSize: 12
                        }

                        Text {
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.key ? root.keyLabel(modelData.key) : ""
                            color: Theme.faint
                            font.family: Theme.ui
                            font.pixelSize: 10
                        }

                        HoverHandler {
                            id: actionHover
                        }

                        TapHandler {
                            onTapped: {
                                root.menuCursor = index;
                                root.runMenu();
                            }
                        }
                    }
                }

                Rectangle {
                    width: menuColumn.width
                    height: 1
                    color: Theme.border
                }

                TextInput {
                    id: menuField

                    width: menuColumn.width
                    height: 28
                    leftPadding: 10
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.fg
                    font.family: Theme.ui
                    font.pixelSize: 12
                    onTextChanged: root.menuCursor = 0

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        visible: menuField.text === ""
                        text: "Search actions\u2026"
                        color: Theme.faint
                        font: menuField.font
                    }

                    Keys.onPressed: event => {
                        const ctrl = event.modifiers & Qt.ControlModifier;
                        const n = root.menuActions.length;
                        if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_N)) {
                            if (n > 0)
                                root.menuCursor = (root.menuCursor + 1) % n;
                        } else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_P)) {
                            if (n > 0)
                                root.menuCursor = (root.menuCursor - 1 + n) % n;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            root.runMenu();
                        } else if (event.key === Qt.Key_Escape || (ctrl && event.key === Qt.Key_K)) {
                            root.closeMenu();
                        } else {
                            return;
                        }
                        event.accepted = true;
                    }
                }
            }
        }
    }
}

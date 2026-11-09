// The control centre's display setups (services/Displays.qml): one card per
// saved setup, drawn as its monitors to scale, the connected monitors' first.
// A click applies one, a right click renames it, dragging moves it (the order
// Mod+M cycles in), + names the current layout, Arrange opens wdisplays to make
// one. Setups for other monitors are hidden until asked for, then listed
// dimmed, so they can be deleted.
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs
import qs.components
import qs.services

ColumnLayout {
    id: root

    required property color accent
    property bool naming: false
    // The setup the name field renames; empty while it names the current layout.
    property string renaming: ""
    // The card being dragged, and the order the others make room for meanwhile.
    property string dragName: ""
    property var dragOrder: []

    function startNaming(): void {
        root.renaming = "";
        root.naming = true;
        nameInput.text = "";
        nameInput.forceActiveFocus();
    }

    function startRenaming(name: string): void {
        root.renaming = name;
        root.naming = true;
        nameInput.text = name;
        nameInput.selectAll();
        nameInput.forceActiveFocus();
    }

    function commit(): void {
        const name = nameInput.text.trim();
        if (name === "")
            return;
        if (root.renaming !== "")
            Displays.rename(root.renaming, name);
        else
            Displays.save(name);
        root.naming = false;
    }

    // Moves the dragged card to the cell under its centre, within its group.
    function retarget(cx: real, cy: real, fits: bool): void {
        const rows = Math.ceil(root.dragOrder.length / grid.columns);
        const col = Math.max(0, Math.min(grid.columns - 1, Math.floor(cx / grid.cellWidth)));
        const row = Math.max(0, Math.min(rows - 1, Math.floor(cy / grid.cellHeight)));
        const first = fits ? 0 : grid.fitting;
        const last = fits ? grid.fitting - 1 : root.dragOrder.length - 1;
        const target = Math.max(first, Math.min(last, row * grid.columns + col));
        if (root.dragOrder.indexOf(root.dragName) === target)
            return;
        const order = root.dragOrder.filter(n => n !== root.dragName);
        order.splice(target, 0, root.dragName);
        root.dragOrder = order;
    }

    Layout.fillWidth: true
    spacing: 6

    component Chip: Rectangle {
        id: chip

        required property string label
        property bool primary: false

        signal activated

        implicitWidth: chipLabel.implicitWidth + 14
        implicitHeight: 20
        radius: Theme.pillRadius
        color: chip.primary ? (chipHover.hovered ? Qt.lighter(root.accent, 1.1) : root.accent) : (chipHover.hovered ? Theme.alpha(Theme.fg, 0.14) : Theme.alpha(Theme.fg, 0.07))

        Text {
            id: chipLabel

            anchors.centerIn: parent
            text: chip.label
            color: chip.primary ? Theme.ink : Theme.fg
            font.family: Theme.ui
            font.pixelSize: 10
            font.weight: Font.Medium
        }

        HoverHandler {
            id: chipHover

            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            onSingleTapped: chip.activated()
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6

        SectionLabel {
            Layout.fillWidth: true
            text: "Displays"
        }

        Chip {
            label: "Arrange"
            onActivated: Quickshell.execDetached(Config.wdisplays)
        }

        GlyphButton {
            glyph: Config.glyph.plus
            glyphSize: 10
            filled: root.naming && root.renaming === ""
            tint: root.accent
            onClicked: root.naming && root.renaming === "" ? root.naming = false : root.startNaming()
        }
    }

    Rectangle {
        Layout.fillWidth: true
        visible: root.naming
        implicitHeight: 30
        radius: Theme.rowRadius
        color: Theme.well

        RowLayout {
            anchors.fill: parent
            anchors.margins: 4
            spacing: 6

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: Theme.rowRadius - 2
                color: "transparent"
                border.width: 1
                border.color: nameInput.activeFocus ? root.accent : Theme.border

                Text {
                    anchors.fill: nameInput
                    visible: nameInput.text === ""
                    text: root.renaming !== "" ? "Rename " + root.renaming : "Name the current layout"
                    color: Theme.faint
                    font: nameInput.font
                    verticalAlignment: Text.AlignVCenter
                }

                TextInput {
                    id: nameInput

                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    color: Theme.fg
                    selectionColor: root.accent
                    selectedTextColor: Theme.ink
                    font.family: Theme.ui
                    font.pixelSize: 11
                    onAccepted: root.commit()
                    Keys.onEscapePressed: event => {
                        root.naming = false;
                        event.accepted = true;
                    }
                }
            }

            Chip {
                label: root.renaming !== "" ? "Rename" : (Displays.has(nameInput.text) ? "Replace" : "Save")
                primary: nameInput.text.trim() !== ""
                onActivated: root.commit()
            }
        }
    }

    Rectangle {
        Layout.fillWidth: true
        visible: !Displays.anyFits && !root.naming
        implicitHeight: 44
        radius: Theme.rowRadius
        color: Theme.well

        Text {
            anchors.centerIn: parent
            width: parent.width - 20
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: Displays.setups.length === 0 ? "No saved layouts - arrange the screens, then + to save" : "No saved layout for these screens - + saves this one"
            color: Theme.faint
            font.family: Theme.ui
            font.pixelSize: 11
        }
    }

    Item {
        id: grid

        readonly property int columns: 3
        readonly property int gap: 6
        readonly property int cardHeight: 92
        readonly property real cellWidth: (grid.width + grid.gap) / grid.columns
        readonly property int cellHeight: grid.cardHeight + grid.gap
        // The connected monitors' setups come first; a card moves only among its own group.
        readonly property int fitting: Displays.setups.filter(s => s.fits).length
        readonly property int other: Displays.setups.length - grid.fitting
        readonly property int shown: Displays.showOther ? Displays.setups.length : grid.fitting

        Layout.fillWidth: true
        visible: grid.shown > 0
        implicitHeight: Math.ceil(grid.shown / grid.columns) * grid.cellHeight - grid.gap

        Repeater {
            model: Displays.ordered

            delegate: Rectangle {
                id: card

                required property var modelData
                required property int index
                readonly property var on: card.modelData.outputs.filter(o => o.on)
                readonly property var off: card.modelData.outputs.filter(o => !o.on)
                readonly property bool fits: card.modelData.fits
                readonly property bool active: card.modelData.active
                readonly property bool held: root.dragName === card.modelData.name
                readonly property int slot: root.dragName !== "" ? root.dragOrder.indexOf(card.modelData.name) : card.index
                property real grabX: 0
                property real grabY: 0

                width: grid.cellWidth - grid.gap
                height: grid.cardHeight
                x: card.held ? card.grabX + drag.activeTranslation.x : (card.slot % grid.columns) * grid.cellWidth
                y: card.held ? card.grabY + drag.activeTranslation.y : Math.floor(card.slot / grid.columns) * grid.cellHeight
                z: card.held ? 1 : 0
                radius: Theme.rowRadius
                color: card.active ? Theme.alpha(root.accent, 0.12) : (cardHover.hovered || card.held ? Theme.alpha(Theme.fg, 0.05) : Theme.well)
                border.width: 1
                border.color: card.active ? root.accent : (cardHover.hovered || card.held ? Theme.alpha(Theme.fg, 0.18) : "transparent")
                visible: card.fits || Displays.showOther
                opacity: card.fits ? 1 : 0.45

                Behavior on x {
                    enabled: !card.held

                    NumberAnimation {
                        duration: 120
                        easing.type: Easing.OutCubic
                    }
                }

                Behavior on y {
                    enabled: !card.held

                    NumberAnimation {
                        duration: 120
                        easing.type: Easing.OutCubic
                    }
                }

                HoverHandler {
                    id: cardHover

                    cursorShape: card.held ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                }

                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    // The remove button's tap reaches the card too.
                    onSingleTapped: if (!removeHover.hovered && card.fits && !card.active)
                        Displays.apply(card.modelData.name)
                }

                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onSingleTapped: root.startRenaming(card.modelData.name)
                }

                DragHandler {
                    id: drag

                    target: null
                    onActiveChanged: {
                        if (drag.active) {
                            card.grabX = card.x;
                            card.grabY = card.y;
                            root.dragOrder = Displays.ordered.map(s => s.name);
                            root.dragName = card.modelData.name;
                        } else if (card.held) {
                            const order = root.dragOrder;
                            root.dragName = "";
                            Displays.order(order);
                        }
                    }
                    onActiveTranslationChanged: if (card.held)
                        root.retarget(card.x + card.width / 2, card.y + card.height / 2, card.fits)
                }

                // The monitors that are on, to scale and centred.
                Item {
                    id: preview

                    readonly property real minX: Math.min(...card.on.map(o => o.x))
                    readonly property real minY: Math.min(...card.on.map(o => o.y))
                    readonly property real spanW: Math.max(...card.on.map(o => o.x + o.w)) - preview.minX
                    readonly property real spanH: Math.max(...card.on.map(o => o.y + o.h)) - preview.minY
                    readonly property real k: card.on.length ? Math.min(preview.width / preview.spanW, preview.height / preview.spanH) : 0

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 8
                    height: 46

                    Repeater {
                        model: card.on

                        delegate: Rectangle {
                            id: screen

                            required property var modelData

                            x: (preview.width - preview.spanW * preview.k) / 2 + (screen.modelData.x - preview.minX) * preview.k
                            y: (preview.height - preview.spanH * preview.k) / 2 + (screen.modelData.y - preview.minY) * preview.k
                            // A hairline apart, so neighbours read as two screens.
                            width: Math.max(2, screen.modelData.w * preview.k - 1.5)
                            height: Math.max(2, screen.modelData.h * preview.k - 1.5)
                            radius: 2
                            color: card.active ? Theme.alpha(root.accent, 0.35) : Theme.alpha(Theme.fg, 0.10)
                            border.width: 1
                            border.color: card.active ? root.accent : Theme.alpha(Theme.fg, 0.28)

                            Text {
                                anchors.fill: parent
                                anchors.margins: 2
                                visible: screen.width > 22 && screen.height > 10
                                text: screen.modelData.label
                                elide: Text.ElideRight
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                color: card.active ? Theme.fg : Theme.dim
                                font.family: Theme.ui
                                font.pixelSize: 8
                            }
                        }
                    }
                }

                ColumnLayout {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: 8
                    anchors.bottomMargin: 6
                    spacing: 0

                    Text {
                        Layout.fillWidth: true
                        text: card.modelData.name
                        elide: Text.ElideRight
                        color: card.active ? Theme.soften(root.accent) : Theme.fg
                        font.family: Theme.ui
                        font.pixelSize: 11
                        font.weight: Font.Medium
                    }
                    Text {
                        Layout.fillWidth: true
                        text: {
                            if (!card.fits)
                                return "Other screens";
                            if (card.off.length)
                                return card.off.map(o => o.label).join(", ") + " off";
                            return card.on.length === 1 ? "1 screen" : card.on.length + " screens";
                        }
                        elide: Text.ElideRight
                        color: Theme.faint
                        font.family: Theme.ui
                        font.pixelSize: 9
                    }
                }

                Rectangle {
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.margins: 3
                    width: 16
                    height: 16
                    radius: 8
                    visible: cardHover.hovered && !card.held
                    color: removeHover.hovered ? Theme.alpha(Theme.red, 0.3) : Theme.alpha(Theme.ink, 0.7)

                    Glyph {
                        anchors.centerIn: parent
                        text: Config.glyph.close
                        size: 9
                        color: removeHover.hovered ? Theme.soften(Theme.red) : Theme.dim
                    }

                    HoverHandler {
                        id: removeHover
                    }

                    TapHandler {
                        onSingleTapped: Displays.remove(card.modelData.name)
                    }
                }
            }
        }
    }

    Rectangle {
        Layout.fillWidth: true
        visible: grid.other > 0
        implicitHeight: 26
        radius: Theme.rowRadius
        color: otherHover.hovered ? Theme.hoverFill : "transparent"

        Text {
            anchors.centerIn: parent
            text: Displays.showOther ? `Hide ${grid.other} for other screens` : `Show ${grid.other} for other screens`
            color: otherHover.hovered ? Theme.fg : Theme.dim
            font.family: Theme.ui
            font.pixelSize: 11
        }

        HoverHandler {
            id: otherHover

            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            onSingleTapped: Displays.showOther = !Displays.showOther
        }
    }

    Text {
        Layout.fillWidth: true
        visible: Displays.error !== ""
        text: Displays.error
        wrapMode: Text.WordWrap
        color: Theme.soften(Theme.red)
        font.family: Theme.ui
        font.pixelSize: 10
    }
}

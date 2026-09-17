// One level of a tray item's DBusMenu: the rows of one `QsMenuOpener`, plus a
// back row when it is a submenu.
//
// A row with children is entered rather than flown out sideways, the shape both
// caelestia-dots/shell and DankMaterialShell settled on: a flyout has to be
// reached by crossing the rows between it and the pointer, and any one of them
// takes the hover and closes it.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs

Rectangle {
    id: panel

    property QsMenuHandle handle: null
    // Title of the row this level was entered through; empty at the root.
    property string back: ""

    signal descend(QsMenuHandle entry, string label)
    signal ascend
    signal activated

    readonly property int pad: 4
    readonly property int rowHeight: 26

    implicitWidth: Math.max(160, list.implicitWidth) + pad * 2
    implicitHeight: list.implicitHeight + pad * 2

    radius: 8
    color: Theme.drawerBg
    border.width: 1
    border.color: Theme.border

    component Row: Rectangle {
        id: rowBg

        // Not `enabled`: that one is Item's, and shadowing it also switches off
        // the handlers below.
        property bool live: true

        signal clicked

        default property alias content: holder.data

        Layout.fillWidth: true
        // A Rectangle takes no size from its anchored child, so the row's width
        // has to be read off the layout or every label ends up elided.
        implicitWidth: holder.implicitWidth + 16
        implicitHeight: panel.rowHeight
        radius: 5
        color: hover.hovered && rowBg.live ? Theme.alpha(Theme.fg, 0.1) : "transparent"

        RowLayout {
            id: holder

            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 8
        }

        HoverHandler {
            id: hover

            cursorShape: rowBg.live ? Qt.PointingHandCursor : Qt.ArrowCursor
        }

        TapHandler {
            enabled: rowBg.live
            onSingleTapped: rowBg.clicked()
        }
    }

    QsMenuOpener {
        id: opener

        menu: panel.handle
    }

    ColumnLayout {
        id: list

        anchors.fill: parent
        anchors.margins: panel.pad
        spacing: 0

        Row {
            visible: panel.back !== ""
            onClicked: panel.ascend()

            Text {
                text: Config.glyph.larrow
                font.family: Theme.icon
                font.pixelSize: 13
                color: Theme.aqua
            }

            Text {
                Layout.fillWidth: true
                text: panel.back
                textFormat: Text.PlainText
                elide: Text.ElideRight
                font.family: Theme.ui
                font.pixelSize: 12
                font.bold: true
                color: Theme.aqua
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: 3
            Layout.bottomMargin: 3
            visible: panel.back !== ""
            implicitHeight: 1
            color: Theme.border
        }

        Repeater {
            model: opener.children

            delegate: Item {
                id: entry

                required property QsMenuEntry modelData

                readonly property bool checkable: modelData.buttonType !== QsMenuButtonType.None

                Layout.fillWidth: true
                implicitWidth: modelData.isSeparator ? 0 : body.implicitWidth
                implicitHeight: modelData.isSeparator ? 7 : panel.rowHeight

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: 1
                    visible: entry.modelData.isSeparator
                    color: Theme.border
                }

                Row {
                    id: body

                    anchors.fill: parent
                    visible: !entry.modelData.isSeparator
                    live: entry.modelData.enabled

                    onClicked: {
                        if (entry.modelData.hasChildren) {
                            panel.descend(entry.modelData, entry.modelData.text);
                            return;
                        }
                        entry.modelData.triggered();
                        panel.activated();
                    }

                    Text {
                        visible: entry.checkable
                        text: entry.modelData.buttonType === QsMenuButtonType.RadioButton ? Config.glyph.dot : Config.glyph.check
                        opacity: entry.modelData.checkState !== Qt.Unchecked ? 1 : 0
                        font.family: Theme.icon
                        font.pixelSize: entry.modelData.buttonType === QsMenuButtonType.RadioButton ? 8 : 11
                        color: Theme.aqua
                    }

                    IconImage {
                        visible: entry.modelData.icon !== ""
                        source: entry.modelData.icon
                        implicitSize: 14
                    }

                    Text {
                        Layout.fillWidth: true
                        text: entry.modelData.text
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        font.family: Theme.ui
                        font.pixelSize: 12
                        color: entry.modelData.enabled ? Theme.fg : Theme.grey
                    }

                    Text {
                        visible: entry.modelData.hasChildren
                        text: Config.glyph.submenu
                        font.family: Theme.icon
                        font.pixelSize: 10
                        color: Theme.alpha(Theme.fg, 0.55)
                    }
                }
            }
        }
    }
}

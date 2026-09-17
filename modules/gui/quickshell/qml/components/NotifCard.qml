// One notification, drawn the same in the popup stack and in the centre.
//
// It takes plain values rather than a Notification, because the centre outlives
// the objects the server destroys when a client closes its notification.
//
// Left click activates, right click dismisses - mako's gestures, and it keeps
// the card free of a close button: a tap handler on the card is also told about
// taps its own buttons took, so the action row is a sibling of the tap area
// rather than a child of it.
import QtQuick
import QtQuick.Layouts
import qs

Rectangle {
    id: root

    required property string appName
    required property string summary
    required property string body
    // Image or icon URL, "" for the bell fallback.
    required property string iconSource
    required property bool critical
    property string time: ""
    // Live NotificationActions; the centre has none.
    property var actions: []
    property color surface: Theme.alpha("#000000", 0.18)

    signal activated
    signal dismissed
    signal actionInvoked(var action)

    implicitHeight: column.implicitHeight + 24
    radius: 10
    color: hover.hovered ? Qt.lighter(root.surface, 1.3) : root.surface
    border.width: 1
    border.color: root.critical ? Theme.alpha(Theme.red, 0.65) : Theme.border

    HoverHandler {
        id: hover

        cursorShape: Qt.PointingHandCursor
    }

    ColumnLayout {
        id: column

        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        Item {
            id: head

            Layout.fillWidth: true
            // A Rectangle takes no size from an anchor-filled child.
            implicitWidth: headRow.implicitWidth
            implicitHeight: headRow.implicitHeight

            RowLayout {
                id: headRow

                anchors.fill: parent
                spacing: 10

                Rectangle {
                    Layout.alignment: Qt.AlignTop
                    Layout.preferredWidth: 34
                    Layout.preferredHeight: 34
                    radius: 8
                    color: root.critical ? Theme.alpha(Theme.red, 0.22) : Theme.alpha(Theme.fg, 0.08)

                    Image {
                        anchors.fill: parent
                        anchors.margins: 5
                        visible: root.iconSource !== ""
                        source: root.iconSource
                        fillMode: Image.PreserveAspectFit
                        sourceSize.width: 48
                        sourceSize.height: 48
                        asynchronous: true
                    }

                    Glyph {
                        anchors.centerIn: parent
                        visible: root.iconSource === ""
                        text: Config.glyph.bell
                        size: 15
                        color: root.critical ? Theme.red : Theme.alpha(Theme.fg, 0.55)
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Text {
                            Layout.fillWidth: true
                            text: root.appName
                            elide: Text.ElideRight
                            color: root.critical ? Theme.red : Theme.alpha(Theme.fg, 0.45)
                            font.family: Theme.ui
                            font.pixelSize: 10
                            font.bold: true
                        }

                        Text {
                            visible: root.time !== ""
                            text: root.time
                            color: Theme.alpha(Theme.fg, 0.35)
                            font.family: Theme.ui
                            font.pixelSize: 10
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: root.summary !== ""
                        text: root.summary
                        elide: Text.ElideRight
                        color: Theme.fg
                        font.family: Theme.ui
                        font.pixelSize: 13
                        font.bold: true
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: root.body !== ""
                        text: root.body
                        // The server advertises markup, so bodies arrive as the
                        // spec's HTML subset.
                        textFormat: Text.StyledText
                        wrapMode: Text.Wrap
                        maximumLineCount: 4
                        elide: Text.ElideRight
                        color: Theme.alpha(Theme.fg, 0.75)
                        font.family: Theme.ui
                        font.pixelSize: 12
                    }
                }
            }

            TapHandler {
                acceptedButtons: Qt.LeftButton
                onSingleTapped: root.activated()
            }

            TapHandler {
                acceptedButtons: Qt.RightButton
                onSingleTapped: root.dismissed()
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: root.actions.length > 0
            spacing: 6

            Repeater {
                model: root.actions

                Rectangle {
                    id: button

                    required property var modelData

                    Layout.fillWidth: true
                    implicitHeight: 28
                    radius: 6
                    color: buttonHover.hovered ? Theme.alpha(Theme.fg, 0.18) : Theme.alpha(Theme.fg, 0.09)

                    Text {
                        anchors.centerIn: parent
                        width: parent.width - 16
                        text: button.modelData.text
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        color: Theme.fg
                        font.family: Theme.ui
                        font.pixelSize: 11
                    }

                    HoverHandler {
                        id: buttonHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        onSingleTapped: root.actionInvoked(button.modelData)
                    }
                }
            }
        }
    }
}

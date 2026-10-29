// One notification, drawn the same in the popup stack and in the centre.
//
// It takes plain values rather than a Notification, because the centre outlives
// the objects the server destroys when a client closes its notification.
//
// Left click activates, right click dismisses - mako's gestures. A tap handler
// on the card is also told about taps its own buttons took, so the action row
// is a sibling of the tap area rather than a child of it.
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
    property color surface: Theme.well

    signal activated
    signal dismissed
    signal actionInvoked(var action)

    implicitHeight: column.implicitHeight + 20
    radius: Theme.rowRadius
    color: root.surface
    clip: true

    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: hover.hovered ? Theme.hoverFill : "transparent"
    }

    // Urgent rail.
    Rectangle {
        visible: root.critical
        width: 3
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        color: Theme.red
    }

    HoverHandler {
        id: hover

        cursorShape: Qt.PointingHandCursor
    }

    ColumnLayout {
        id: column

        anchors.fill: parent
        anchors.margins: 10
        anchors.leftMargin: 12
        spacing: 8

        Item {
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
                    Layout.preferredWidth: 28
                    Layout.preferredHeight: 28
                    radius: Theme.rowRadius
                    color: root.critical ? Theme.alpha(Theme.red, 0.2) : Theme.alpha(Theme.fg, 0.08)

                    Image {
                        anchors.fill: parent
                        anchors.margins: 4
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
                        size: 13
                        color: root.critical ? Theme.red : Theme.dim
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
                            color: root.critical ? Theme.red : Theme.dim
                            font.family: Theme.ui
                            font.pixelSize: 10
                            font.weight: Font.DemiBold
                        }

                        Text {
                            visible: root.time !== ""
                            text: root.time
                            color: Theme.faint
                            font.family: Theme.ui
                            font.pixelSize: 10
                            font.features: { "tnum": 1 }
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: root.summary !== ""
                        text: root.summary
                        elide: Text.ElideRight
                        color: Theme.fg
                        font.family: Theme.ui
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: root.body !== ""
                        // Bodies arrive as the spec's HTML subset, where a
                        // newline is whitespace; senders mean them as breaks.
                        text: root.body.replace(/\n/g, "<br/>")
                        textFormat: Text.StyledText
                        wrapMode: Text.Wrap
                        maximumLineCount: 4
                        elide: Text.ElideRight
                        color: Theme.dim
                        font.family: Theme.ui
                        font.pixelSize: 11
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
            id: actionRow

            // "default" is what clicking the card invokes; senders often leave it unlabeled.
            readonly property var buttons: root.actions.filter(action => action.identifier !== "default")

            Layout.fillWidth: true
            Layout.leftMargin: 38
            visible: buttons.length > 0
            spacing: 6

            Repeater {
                model: actionRow.buttons

                Rectangle {
                    id: button

                    required property var modelData

                    implicitWidth: Math.min(buttonLabel.implicitWidth + 20, 160)
                    implicitHeight: 24
                    radius: Theme.rowRadius
                    color: buttonHover.hovered ? Theme.alpha(Theme.fg, 0.14) : Theme.alpha(Theme.fg, 0.07)

                    Text {
                        id: buttonLabel

                        anchors.centerIn: parent
                        width: Math.min(implicitWidth, parent.width - 20)
                        text: button.modelData.text
                        elide: Text.ElideRight
                        color: Theme.fg
                        font.family: Theme.ui
                        font.pixelSize: 11
                        font.weight: Font.Medium
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

            Item {
                Layout.fillWidth: true
            }
        }
    }
}

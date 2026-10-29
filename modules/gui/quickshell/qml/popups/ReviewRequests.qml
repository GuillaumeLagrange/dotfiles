// Pull requests awaiting my review: one card per PR, railed by its checks.
// Clicking one opens it the way picking it in the reviews picker does.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs
import qs.components
import qs.services

PopupPanel {
    id: root

    minContentWidth: 540

    // Sampled on open; the ages only need to be right when looked at.
    property real now: Date.now() / 1000
    onOpenChanged: if (open)
        now = Date.now() / 1000

    function age(at: real): string {
        const secs = Math.max(0, root.now - at);
        if (secs < 3600)
            return `${Math.max(1, Math.floor(secs / 60))}m`;
        if (secs < 86400)
            return `${Math.floor(secs / 3600)}h`;
        return `${Math.floor(secs / 86400)}d`;
    }

    function rail(checks): color {
        switch (checks) {
        case "Success":
            return Theme.green;
        case "Failure":
            return Theme.red;
        case "Pending":
            return Theme.yellow;
        default:
            return Theme.grey;
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8

        RowLayout {
            Layout.fillWidth: true

            Text {
                Layout.fillWidth: true
                text: "Review requested"
                color: Theme.grey
                font.family: Theme.mono
                font.pixelSize: 12
            }

            Text {
                text: `updated ${root.age(Reviews.fetchedAt)} ago`
                color: Theme.grey
                font.family: Theme.mono
                font.pixelSize: 10
            }
        }

        Repeater {
            model: Reviews.prs

            delegate: Rectangle {
                id: card

                required property var modelData

                Layout.fillWidth: true
                implicitHeight: inner.implicitHeight + 16
                radius: 8
                color: cardHover.hovered ? Theme.alpha("#000000", 0.24) : Theme.alpha("#000000", 0.14)

                HoverHandler {
                    id: cardHover

                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    onSingleTapped: {
                        root.close();
                        Quickshell.execDetached(Config.reviewPr.concat([card.modelData.url]));
                    }
                }

                RowLayout {
                    id: inner

                    anchors.fill: parent
                    anchors.margins: 8
                    anchors.leftMargin: 10
                    spacing: 10

                    Rectangle {
                        Layout.preferredWidth: 3
                        Layout.fillHeight: true
                        radius: 3
                        color: root.rail(card.modelData.checks)
                    }

                    ClippingRectangle {
                        Layout.preferredWidth: 32
                        Layout.preferredHeight: 32
                        Layout.alignment: Qt.AlignVCenter
                        radius: 16
                        color: Theme.alpha(Theme.fg, 0.1)

                        // The picker's on-disk copy, else GitHub's.
                        Image {
                            anchors.fill: parent
                            source: `file://${Reviews.dir}/avatars/${card.modelData.author}`
                            onStatusChanged: if (status === Image.Error && card.modelData.avatar_url)
                                source = card.modelData.avatar_url
                            sourceSize.width: 64
                            sourceSize.height: 64
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 3

                        Text {
                            Layout.fillWidth: true
                            text: `${card.modelData.repo} #${card.modelData.number}` + (card.modelData.draft ? "  draft" : "")
                            color: Theme.alpha(Theme.fg, 0.55)
                            font.family: Theme.mono
                            font.pixelSize: 10
                        }

                        Text {
                            Layout.fillWidth: true
                            text: card.modelData.title
                            color: Theme.fg
                            elide: Text.ElideRight
                            font.family: Theme.mono
                            font.pixelSize: 13
                            font.weight: Font.Bold
                        }

                        RowLayout {
                            spacing: 8

                            Text {
                                text: card.modelData.author
                                color: Theme.alpha(Theme.fg, 0.6)
                                font.family: Theme.mono
                                font.pixelSize: 11
                            }

                            Text {
                                text: `+${card.modelData.additions}`
                                color: Theme.green
                                font.family: Theme.mono
                                font.pixelSize: 11
                            }

                            Text {
                                text: `-${card.modelData.deletions}`
                                color: Theme.red
                                font.family: Theme.mono
                                font.pixelSize: 11
                            }

                            Text {
                                text: root.age(card.modelData.updated_at)
                                color: Theme.alpha(Theme.fg, 0.45)
                                font.family: Theme.mono
                                font.pixelSize: 11
                            }
                        }
                    }
                }
            }
        }
    }
}

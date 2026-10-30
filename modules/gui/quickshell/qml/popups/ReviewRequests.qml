// Pull requests awaiting my review, as the reviews picker lists them: one card
// per PR, railed by its checks, a GitHub stack's members gathered under its
// heading, top first. Clicking a card opens it the way picking it in the picker
// does; the title's buttons refresh the list and open the picker itself.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs
import qs.components
import qs.services

PopupPanel {
    id: root
    accent: Theme.green

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

    // Where the tree's line runs, left of a stack's cards.
    readonly property int treeX: 7
    readonly property int indent: 18

    ColumnLayout {
        anchors.fill: parent
        spacing: 10

        PanelTitle {
            glyph: Config.glyph.pullRequest
            text: "Review requests"
            accent: root.accent

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Reviews.refreshing ? "refreshing" : Reviews.fetchedAt > 0 ? `updated ${root.age(Reviews.fetchedAt)} ago` : "never fetched"
                color: Theme.faint
                font.family: Theme.ui
                font.features: { "tnum": 1 }
                font.pixelSize: 10
            }

            GlyphButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: Config.glyph.refresh
                glyphSize: 12
                opacity: Reviews.refreshing ? 0.4 : 1
                onClicked: {
                    Reviews.refresh();
                    root.now = Date.now() / 1000;
                }
            }

            GlyphButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: Config.glyph.terminal
                glyphSize: 12
                onClicked: {
                    root.close();
                    Quickshell.execDetached(Config.review);
                }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: Reviews.error !== ""
            text: Reviews.error
            color: Theme.red
            wrapMode: Text.Wrap
            font.family: Theme.ui
            font.pixelSize: 11
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6

            Repeater {
                model: Reviews.rows

                delegate: Loader {
                    id: row

                    required property var modelData

                    Layout.fillWidth: true
                    sourceComponent: modelData.kind === "stack" ? stackHead : prCard
                }
            }
        }
    }

    Component {
        id: stackHead

        RowLayout {
            readonly property var stack: parent.modelData

            spacing: 8

            Item {
                Layout.preferredWidth: root.indent - 4
                Layout.fillHeight: true

                Glyph {
                    anchors.centerIn: parent
                    text: Config.glyph.stack
                    color: root.accent
                    size: 12
                }

                Rectangle {
                    x: root.treeX
                    y: parent.height / 2 + 9
                    width: 1
                    height: parent.height / 2 - 9 + 6
                    color: Theme.faint
                }
            }

            Text {
                text: `Stack of ${parent.stack.size}`
                color: Theme.fg
                font.family: Theme.ui
                font.pixelSize: 12
                font.weight: Font.DemiBold
            }

            Text {
                Layout.fillWidth: true
                text: `${parent.stack.repo} \u2192 ${parent.stack.base}`
                color: Theme.faint
                elide: Text.ElideRight
                font.family: Theme.ui
                font.pixelSize: 11
            }
        }
    }

    Component {
        id: prCard

        Item {
            id: card

            readonly property var pr: parent.modelData
            readonly property bool inStack: pr.place !== "alone"
            readonly property bool open: pr.state === "Open"
            // As in the picker: the PRs asked of me, and open members of their stacks.
            readonly property bool pickable: pr.listed || open

            implicitHeight: body.implicitHeight

            // The tree: down the whole card to the next member, half of it for the last.
            Rectangle {
                visible: card.inStack
                x: root.treeX
                y: -6
                width: 1
                height: card.pr.place === "last" ? body.height / 2 + 6 : card.height + 6
                color: Theme.faint
            }

            Rectangle {
                visible: card.inStack
                x: root.treeX
                y: body.height / 2
                width: root.indent - root.treeX - 2
                height: 1
                color: Theme.faint
            }

            Rectangle {
                id: body

                x: card.inStack ? root.indent : 0
                width: card.width - x
                implicitHeight: inner.implicitHeight + 16
                radius: Theme.rowRadius
                color: Theme.well
                opacity: card.open ? 1 : 0.6

                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    color: card.pickable && cardHover.hovered ? Theme.hoverFill : "transparent"
                }

                HoverHandler {
                    id: cardHover

                    cursorShape: card.pickable ? Qt.PointingHandCursor : Qt.ArrowCursor
                }

                TapHandler {
                    enabled: card.pickable
                    onSingleTapped: {
                        root.close();
                        Quickshell.execDetached(Config.reviewPr.concat([card.pr.url]));
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
                        color: root.rail(card.pr.checks)
                    }

                    ClippingRectangle {
                        Layout.preferredWidth: 32
                        Layout.preferredHeight: 32
                        Layout.alignment: Qt.AlignVCenter
                        radius: 16
                        color: Theme.hoverFill

                        Image {
                            anchors.fill: parent
                            source: card.pr.avatar ?? ""
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
                            text: {
                                let t = `${card.pr.repo} #${card.pr.number}`;
                                if (card.pr.draft && card.open)
                                    t += "  draft";
                                if (!card.open)
                                    t += `  ${card.pr.state.toLowerCase()}`;
                                else if (!card.pr.listed)
                                    t += "  not requested";
                                return t;
                            }
                            color: Theme.faint
                            font.family: Theme.ui
                            font.pixelSize: 10
                        }

                        Text {
                            Layout.fillWidth: true
                            text: card.pr.title
                            color: card.pr.listed ? Theme.fg : Theme.dim
                            elide: Text.ElideRight
                            font.family: Theme.ui
                            font.pixelSize: 12
                            font.weight: card.pr.listed ? Font.DemiBold : Font.Normal
                        }

                        RowLayout {
                            spacing: 8

                            Text {
                                text: card.pr.author
                                color: Theme.dim
                                font.family: Theme.ui
                                font.pixelSize: 11
                            }

                            Text {
                                text: `+${card.pr.additions}`
                                color: Theme.green
                                font.family: Theme.ui
                                font.features: { "tnum": 1 }
                                font.pixelSize: 11
                            }

                            Text {
                                text: `-${card.pr.deletions}`
                                color: Theme.red
                                font.family: Theme.ui
                                font.features: { "tnum": 1 }
                                font.pixelSize: 11
                            }

                            Text {
                                text: root.age(card.pr.updated_at)
                                color: Theme.faint
                                font.family: Theme.ui
                                font.features: { "tnum": 1 }
                                font.pixelSize: 11
                            }
                        }
                    }
                }
            }
        }
    }
}

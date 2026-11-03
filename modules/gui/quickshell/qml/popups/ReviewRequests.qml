// Pull requests as the reviews picker lists them, in its tabs: awaiting my
// review, reviewed lately, and mine. One card per PR, railed by its checks, a
// GitHub stack's members gathered under its heading, top first. Clicking a card
// opens it the way picking it in the picker does; the title's buttons refresh
// the lists and open the picker itself. Typing filters the tab's PRs, Tab and
// Shift+Tab cycle the tabs, Up/Down and Enter pick one.
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
    accent: Theme.green

    panelWidth: 540 + root.pad * 2

    // The picker's tabs, in its order.
    readonly property var tabs: [
        { key: "requested", label: "Needs your review", empty: "Nothing awaits your review" },
        { key: "reviewed", label: "Reviewed", empty: "Nothing reviewed in the last 14 days" },
        { key: "mine", label: "My PRs", empty: "You have no open pull request" }
    ]
    // Kept by the service: the last one picked, on every screen.
    readonly property string tab: Reviews.tab
    readonly property var feed: Reviews[root.tab]
    readonly property var current: root.tabs.find(t => t.key === root.tab)
    readonly property var rows: Reviews.showStale ? root.feed.all : root.feed.rows

    // Filtered, the PRs stand alone, best match first: a stack's tree means
    // nothing once some of its members are gone.
    readonly property bool filtering: find.query !== ""
    readonly property var matching: root.visibleRows()
    // The PR the arrow keys are on, by url: a refresh replaces every row.
    property string cursor: ""

    function visibleRows(): var {
        if (find.query === "")
            return root.rows;
        return find.filter(root.rows.filter(r => r.kind !== "stack"), pr => `${pr.title} ${pr.repo} #${pr.number} ${pr.author}`);
    }

    // As in the picker: the PRs asked of me, and open members of their stacks.
    function pickable(pr: var): bool {
        return pr.kind !== "stack" && (pr.listed || pr.state === "Open");
    }

    function pick(pr: var): void {
        root.close();
        // Mine opens where its branch is checked out, not in the reviews session.
        Quickshell.execDetached(root.tab === "mine" ? Config.reviewMine.concat([pr.url, pr.branch]) : Config.reviewPr.concat([pr.url]));
    }

    // Puts the cursor on the first PR, which typing makes the best match.
    function first(): void {
        root.cursor = root.visibleRows().find(r => root.pickable(r))?.url ?? "";
        list.positionViewAtBeginning();
    }

    function step(delta: int): void {
        const picks = root.matching.filter(r => root.pickable(r));
        if (picks.length === 0)
            return;
        const i = picks.findIndex(pr => pr.url === root.cursor);
        const next = i < 0 ? (delta > 0 ? 0 : picks.length - 1) : Math.max(0, Math.min(picks.length - 1, i + delta));
        root.cursor = picks[next].url;
        list.positionViewAtIndex(root.matching.indexOf(picks[next]), ListView.Contain);
    }

    function cycle(delta: int): void {
        const i = root.tabs.findIndex(t => t.key === root.tab);
        Reviews.tab = root.tabs[(i + delta + root.tabs.length) % root.tabs.length].key;
    }

    // Deferred: `rows` still holds the previous tab while this runs.
    onTabChanged: if (root.visible)
        Qt.callLater(root.first)

    // Sampled on open; the ages only need to be right when looked at.
    property real now: Date.now() / 1000
    onShown: {
        root.now = Date.now() / 1000;
        root.first();
        list.forceActiveFocus();
    }
    onHidden: {
        find.query = "";
        root.cursor = "";
    }

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
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 10

        PanelTitle {
            glyph: Config.glyph.pullRequest
            text: "Pull requests"
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

        Rectangle {
            Layout.fillWidth: true
            visible: root.rows.length === 0
            implicitHeight: 44
            radius: Theme.rowRadius
            color: Theme.well

            Text {
                anchors.centerIn: parent
                text: root.feed.stale > 0 ? "Only stale pull requests, not updated in 60 days" : root.current.empty
                color: Theme.faint
                font.family: Theme.ui
                font.pixelSize: 11
            }
        }

        FindBar {
            id: find

            accent: root.accent
            empty: root.matching.length === 0
            onQueryChanged: root.first()
        }

        ListView {
            id: list

            function pickCursor(): void {
                const pr = root.matching.find(r => root.pickable(r) && r.url === root.cursor);
                if (pr)
                    root.pick(pr);
            }

            Layout.fillWidth: true
            // A ListView has no implicit height: as tall as its rows, up to what
            // the output leaves above the bar.
            Layout.preferredHeight: Math.min(list.contentHeight, Math.max(200, (root.screen?.height ?? 1000) - 260))
            visible: root.matching.length > 0
            clip: true
            spacing: 6
            model: root.matching
            keyNavigationEnabled: false
            Keys.onUpPressed: root.step(-1)
            Keys.onDownPressed: root.step(1)
            Keys.onTabPressed: root.cycle(1)
            Keys.onBacktabPressed: root.cycle(-1)
            Keys.onReturnPressed: list.pickCursor()
            Keys.onEnterPressed: list.pickCursor()
            Keys.onEscapePressed: event => {
                if (find.query !== "")
                    find.query = "";
                else
                    event.accepted = false;
            }
            Keys.onPressed: event => {
                event.accepted = find.type(event);
            }

            // Shown only while the list is capped, and the rows give up its width.
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

            delegate: Loader {
                required property var modelData

                width: list.width - (vbar.visible ? vbar.implicitWidth + 2 : 0)
                sourceComponent: modelData.kind === "stack" ? stackHead : prCard
            }
        }

        // Stale PRs are hidden until asked for, here and in the picker (`a`).
        Rectangle {
            Layout.fillWidth: true
            visible: root.feed.stale > 0
            implicitHeight: 26
            radius: Theme.rowRadius
            color: staleHover.hovered ? Theme.hoverFill : "transparent"

            Text {
                anchors.centerIn: parent
                text: Reviews.showStale ? `Hide ${root.feed.stale} stale` : `Show ${root.feed.stale} stale`
                color: staleHover.hovered ? Theme.fg : Theme.dim
                font.family: Theme.ui
                font.pixelSize: 11
            }

            HoverHandler {
                id: staleHover

                cursorShape: Qt.PointingHandCursor
            }

            TapHandler {
                onSingleTapped: Reviews.showStale = !Reviews.showStale
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: segs.implicitHeight + 4
            radius: Theme.rowRadius
            color: Theme.well

            RowLayout {
                id: segs

                anchors.fill: parent
                anchors.margins: 2
                spacing: 2

                Repeater {
                    model: root.tabs

                    Rectangle {
                        id: seg

                        required property var modelData
                        readonly property bool selected: root.tab === modelData.key
                        readonly property color ink: selected ? Theme.ink : (segHover.hovered ? Theme.fg : Theme.dim)

                        Layout.fillWidth: true
                        implicitHeight: 26
                        radius: Theme.rowRadius - 1
                        color: selected ? root.accent : (segHover.hovered ? Theme.hoverFill : "transparent")

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: 6

                            Text {
                                text: seg.modelData.label
                                color: seg.ink
                                font.family: Theme.ui
                                font.pixelSize: 11
                                font.weight: seg.selected ? Font.DemiBold : Font.Normal
                            }

                            Text {
                                text: Reviews[seg.modelData.key].count
                                color: seg.ink
                                opacity: 0.7
                                font.family: Theme.ui
                                font.features: { "tnum": 1 }
                                font.pixelSize: 10
                            }
                        }

                        HoverHandler {
                            id: segHover

                            cursorShape: Qt.PointingHandCursor
                        }

                        TapHandler {
                            onSingleTapped: Reviews.tab = seg.modelData.key
                        }
                    }
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
            readonly property bool inStack: pr.place !== "alone" && !root.filtering
            readonly property bool open: pr.state === "Open"
            readonly property bool pickable: root.pickable(pr)
            readonly property bool current: card.pickable && root.cursor === pr.url

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
                border.width: card.current ? 1 : 0
                border.color: Theme.alpha(root.accent, 0.6)

                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    color: card.pickable && (cardHover.hovered || card.current) ? Theme.hoverFill : "transparent"
                }

                HoverHandler {
                    id: cardHover

                    cursorShape: card.pickable ? Qt.PointingHandCursor : Qt.ArrowCursor
                }

                TapHandler {
                    enabled: card.pickable
                    acceptedButtons: Qt.LeftButton
                    onSingleTapped: root.pick(card.pr)
                }

                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onSingleTapped: {
                        root.close();
                        Quickshell.execDetached(Config.openUrl.concat([card.pr.url]));
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
                                    t += { requested: "  not requested", reviewed: "  not reviewed", mine: "  not yours" }[root.tab];
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

                            Rectangle {
                                readonly property bool approved: card.pr.decision === "Approved"

                                visible: card.open && !!card.pr.decision
                                implicitWidth: verdict.implicitWidth + 12
                                implicitHeight: verdict.implicitHeight + 4
                                radius: height / 2
                                color: approved ? Theme.green : Theme.red

                                Text {
                                    id: verdict

                                    anchors.centerIn: parent
                                    text: parent.approved ? "✓ Approved" : "✗ Changes requested"
                                    color: Theme.ink
                                    font.family: Theme.ui
                                    font.pixelSize: 10
                                    font.weight: Font.Bold
                                }
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

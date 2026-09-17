// Tooltip chrome: a Bubble sized to its content, placed over the trigger, with
// the tail pointing at the trigger's middle.
//
// A popup window is all a tooltip needs: nothing in it is hovered into or
// clicked.
//
// The content item must `anchors.fill: parent` and carry implicit sizes (a
// ColumnLayout/RowLayout does): the window sizes itself from them.
import QtQuick
import Quickshell
import qs

PopupWindow {
    id: root

    required property Item target
    property int pad: Theme.popupPad
    property real bodyRadius: 8
    // Rows that fill the width report no implicit width of their own, so
    // content that is all fill-width rows would collapse without a floor.
    property int minContentWidth: 0
    readonly property bool hovered: hover.hovered
    // Tail tip, in the window's own coordinates.
    property real tailX: 0

    default property alias content: holder.data
    readonly property Item item: holder.children.length > 0 ? holder.children[0] : null

    // Anchored to the bar window rather than to the pill, which is the route
    // the docs give for placing a popup relative to an item: the rect is set
    // from a coordinate mapping when the anchor resolves, since mapping
    // functions are not reactive. Placing the window ourselves is also what
    // makes the tail exact - its left edge is `rect.x`, so no guessing at what
    // the compositor did with a popup that would not fit.
    anchor {
        window: root.target.QsWindow.window
        edges: Edges.Top | Edges.Left
        gravity: Edges.Top | Edges.Right
    }

    color: "transparent"
    implicitWidth: Math.max(root.minContentWidth, root.item ? root.item.implicitWidth : 0) + root.pad * 2
    implicitHeight: (root.item ? root.item.implicitHeight : 0) + root.pad * 2 + bubble.tailHeight

    // The anchor is resolved once per show, so a panel that grows after opening
    // (a track name, a month with six rows) has to ask for it again.
    onWidthChanged: if (root.visible)
        root.anchor.updateAnchor()

    Connections {
        target: root.anchor

        function onAnchoring(): void {
            const trigger = root.target.mapToItem(null, 0, 0, root.target.width, root.target.height);
            const center = trigger.x + trigger.width / 2;
            const barWidth = root.anchor.window ? root.anchor.window.width : 0;
            const x = Math.max(4, Math.min(barWidth - root.width - 4, center - root.width / 2));
            root.anchor.rect = Qt.rect(x, trigger.y - Theme.popupGap, 1, 1);
            root.tailX = center - x;
        }
    }

    Bubble {
        id: bubble

        anchors.fill: parent
        bodyRadius: root.bodyRadius
        tailX: root.tailX

        HoverHandler {
            id: hover
        }

        Item {
            id: holder

            anchors.fill: parent
            anchors.margins: root.pad
            anchors.bottomMargin: root.pad + bubble.tailHeight
        }
    }
}

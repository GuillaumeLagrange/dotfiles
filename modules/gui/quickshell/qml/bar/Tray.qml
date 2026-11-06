// Native SNI host, folded behind three dots: a row of applet icons is noise
// most of the time, so the pill keeps the bar to a fixed width and unfolds the
// icons inline when the pointer is on it - a drawer in the bar itself, not a
// panel above it, so nothing has to survive the pointer crossing a gap.
//
// Icons are dragged to reorder them, and out of the drawer (the recessed box)
// to pin them beside it, always shown. While dragging, the others already sit
// where the drop leaves them. Places are offsets from the right edge: the bar
// is right-anchored, so the drawer opening leftwards never moves a pin.
import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import Quickshell.Widgets
import qs
import qs.components
import qs.services

Rectangle {
    id: root

    readonly property int iconSize: 18
    readonly property int iconGap: 10
    readonly property int boxPad: 5

    // The dragged icon's index in SystemTray.items, its left edge, and the
    // order a drop would leave, which the tray already shows.
    property int dragIndex: -1
    property real dragX: 0
    property real dragGrab: 0
    property var dragOrder: null
    readonly property bool dragging: root.dragIndex >= 0
    readonly property bool unfolded: gate.open || menu.visible || root.dragging

    // Indices into SystemTray.items, in the saved order; an icon never placed
    // goes to the end of the drawer.
    readonly property var savedOrder: {
        const items = SystemTray.items.values;
        const rank = (list, i) => {
            const at = list.indexOf(items[i].id);
            return at < 0 ? list.length : at;
        };
        const all = items.map((_, i) => i);
        const pinned = all.filter(i => TrayOrder.pins.includes(items[i].id));
        return {
            drawer: all.filter(i => !pinned.includes(i)).sort((a, b) => rank(TrayOrder.drawer, a) - rank(TrayOrder.drawer, b) || a - b),
            pinned: pinned.sort((a, b) => rank(TrayOrder.pins, a) - rank(TrayOrder.pins, b) || a - b)
        };
    }
    readonly property var order: root.dragging ? root.dragOrder : root.savedOrder
    readonly property var geometry: root.geometryOf(root.order)
    // Where the content's right edge sits, which every place is relative to.
    readonly property real edge: root.width - Theme.pillPad

    visible: SystemTray.items.values.length > 0
    implicitWidth: root.geometry.width + Theme.pillPad * 2
    implicitHeight: Theme.pillHeight
    radius: Theme.pillRadius
    color: root.unfolded ? Theme.alpha(Theme.fg, 0.2) : Theme.alpha(Theme.fg, 0.14)
    // The drawer slides rather than snapping the rest of the bar sideways.
    clip: true

    Behavior on implicitWidth {
        NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
        }
    }

    // Each icon's left edge and the drawer box, as offsets from the content's
    // right edge, pins rightmost. While dragging the box stays, even empty, as
    // the place to drop into.
    function geometryOf(order: var): var {
        const xs = {};
        let cursor = 0;
        for (let k = order.pinned.length - 1; k >= 0; k--) {
            cursor -= root.iconSize;
            xs[order.pinned[k]] = cursor;
            cursor -= root.iconGap;
        }
        const pinsLeft = order.pinned.length > 0 ? cursor + root.iconGap : 0;
        const showBox = order.drawer.length > 0 || root.dragging;
        if (!showBox)
            return {
                xs: xs,
                showBox: false,
                boxLeft: 0,
                boxWidth: 0,
                width: -pinsLeft
            };
        const n = order.drawer.length;
        const boxWidth = root.unfolded ? Math.max(n * root.iconSize + (n - 1) * root.iconGap, 0) + root.boxPad * 2 : dots.implicitWidth;
        const boxLeft = cursor - boxWidth;
        order.drawer.forEach((i, k) => {
            xs[i] = root.unfolded ? boxLeft + root.boxPad + k * (root.iconSize + root.iconGap) : boxLeft + (boxWidth - root.iconSize) / 2;
        });
        return {
            xs: xs,
            showBox: true,
            boxLeft: boxLeft,
            boxWidth: boxWidth,
            width: -boxLeft
        };
    }

    // Moves the dragged icon by the layout on screen: past the box's edge is
    // the other section, past a neighbour's centre swaps with it. Each step
    // moves what it is measured against away from the pointer, so a pointer
    // at rest never flips the order back.
    function retarget(): void {
        const g = root.geometry;
        const centre = root.dragX + root.iconSize / 2 - root.edge;
        const section = centre > g.boxLeft + g.boxWidth + root.iconGap / 2 ? "pinned" : "drawer";
        const without = list => list.filter(i => i !== root.dragIndex);
        const order = {
            drawer: without(root.dragOrder.drawer),
            pinned: without(root.dragOrder.pinned)
        };
        const index = order[section].filter(i => g.xs[i] + root.iconSize / 2 < centre).length;
        order[section].splice(index, 0, root.dragIndex);
        if (JSON.stringify(order) !== JSON.stringify(root.dragOrder))
            root.dragOrder = order;
    }

    function drop(): void {
        const items = SystemTray.items.values;
        const ids = list => list.map(i => items[i].id).filter((id, k, all) => all.indexOf(id) === k);
        TrayOrder.save(ids(root.order.drawer), ids(root.order.pinned));
        root.dragIndex = -1;
    }

    Rectangle {
        x: root.edge + root.geometry.boxLeft
        anchors.verticalCenter: parent.verticalCenter
        width: root.geometry.boxWidth
        height: root.iconSize + 2
        radius: Theme.pillRadius - 1
        visible: root.geometry.showBox && root.unfolded
        color: Theme.alpha("#000000", 0.3)
    }

    // Indices shift when an app comes or goes: a drag across that is dropped.
    Connections {
        target: SystemTray.items

        function onValuesChanged(): void {
            root.dragIndex = -1;
        }
    }

    Glyph {
        id: dots

        x: root.edge + root.geometry.boxLeft
        anchors.verticalCenter: parent.verticalCenter
        visible: root.geometry.showBox && !root.unfolded
        text: Config.glyph.more
        color: Theme.fg
    }

    Repeater {
        model: SystemTray.items

        delegate: Item {
            id: entry

            required property SystemTrayItem modelData
            required property int index
            readonly property bool held: root.dragIndex === entry.index
            // Animated relative to the right edge, never the edge itself: the
            // pill's width animates as the drawer opens, and an icon easing
            // after it would drift against the bar.
            property real offset: root.geometry.xs[entry.index] ?? 0
            // What is left of the way from where a drop let go to the slot.
            property real settle: 0

            x: entry.held ? root.dragX : root.edge + entry.offset + entry.settle
            anchors.verticalCenter: parent.verticalCenter
            width: root.iconSize
            height: root.iconSize
            z: entry.held || entry.settle !== 0 ? 1 : 0
            visible: root.unfolded || root.order.pinned.includes(entry.index)

            Behavior on offset {
                enabled: !entry.held

                NumberAnimation {
                    duration: 120
                    easing.type: Easing.OutCubic
                }
            }

            NumberAnimation {
                id: settling

                target: entry
                property: "settle"
                to: 0
                duration: 120
                easing.type: Easing.OutCubic
            }

            IconImage {
                anchors.centerIn: parent
                source: entry.modelData.icon
                implicitSize: root.iconSize
                opacity: iconHover.hovered || entry.held ? 1 : 0.85
            }

            HoverHandler {
                id: iconHover

                cursorShape: entry.held ? Qt.ClosedHandCursor : Qt.PointingHandCursor
            }

            DragHandler {
                id: drag

                target: null
                yAxis.enabled: false
                onCentroidChanged: {
                    if (!entry.held)
                        return;
                    root.dragX = root.mapFromItem(null, drag.centroid.scenePosition.x, 0).x - root.dragGrab;
                    root.retarget();
                }
                onActiveChanged: {
                    if (drag.active) {
                        root.dragGrab = drag.centroid.pressPosition.x;
                        root.dragX = root.mapFromItem(null, drag.centroid.scenePosition.x, 0).x - root.dragGrab;
                        root.dragOrder = root.savedOrder;
                        root.dragIndex = entry.index;
                    } else if (entry.held) {
                        entry.settle = root.dragX - root.edge - entry.offset;
                        settling.restart();
                        root.drop();
                    }
                }
            }

            TapHandler {
                acceptedButtons: Qt.LeftButton
                onSingleTapped: {
                    if (entry.modelData.onlyMenu)
                        root.openMenu(entry.modelData.menu);
                    else
                        entry.modelData.activate();
                }
            }

            TapHandler {
                acceptedButtons: Qt.MiddleButton
                onSingleTapped: entry.modelData.secondaryActivate()
            }

            TapHandler {
                acceptedButtons: Qt.RightButton
                onSingleTapped: root.openMenu(entry.modelData.menu)
            }
        }
    }

    function openMenu(handle: var): void {
        menu.handle = handle;
        menu.open();
    }

    HoverHandler {
        id: hover
    }

    // The pill sits between others, so the pointer crosses it on the way
    // elsewhere: a dwell keeps the drawer from flicking open in passing, and
    // the same delay on the way out keeps a clipped icon from sliding away
    // under a pointer that only left it for a moment.
    HoverGate {
        id: gate

        triggerHovered: hover.hovered
        openDelay: 200
        closeDelay: 200
    }

    TrayMenu {
        id: menu

        target: root
    }
}

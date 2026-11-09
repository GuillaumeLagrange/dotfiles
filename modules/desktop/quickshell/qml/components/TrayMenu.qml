// A tray item's DBusMenu, drawn in QML.
//
// QsMenuAnchor hands the menu to a QMenu, which needs `pragma UseQApplication`;
// QApplication then loads the session's Qt widget theme plugins (stylix exports
// QT_QPA_PLATFORMTHEME and QT_STYLE_OVERRIDE), built against a different Qt than
// quickshell's, and the shell hangs before it loads. Drawing the menu here also
// keeps it in the bar's palette rather than the Qt widget style's.
//
// The window covers the whole screen, bar included: an xdg_popup grab only
// reports clicks that land outside the client, so a window sized to the menu
// stayed open when the click hit another part of the bar.
//
// Submenus are pushed onto a StackView rather than flown out sideways: a
// flyout has to be reached by crossing the rows between it and the pointer,
// any one of which takes the hover and closes it. The stack also keeps every
// level's `QsMenuOpener` alive, which a repointed one would not be.
import QtQuick
import QtQuick.Controls
import Quickshell
import qs
import qs.components

PopupWindow {
    id: root

    // Tray icon the menu belongs to; also names the window it is anchored in.
    required property Item target
    property QsMenuHandle handle: null

    readonly property var bar: root.target.QsWindow.window
    // Sampled when the menu opens: `itemRect` is a call, so as a binding it
    // would keep whatever the bar's layout happened to be at creation.
    property real targetCenter: 0

    function open(): void {
        if (root.handle === null)
            return;
        const rect = root.target.QsWindow.itemRect(root.target);
        root.targetCenter = rect.x + rect.width / 2;
        stack.push(level, {
            handle: root.handle
        });
        root.visible = true;
    }

    function close(): void {
        root.visible = false;
    }

    function toggle(): void {
        if (root.visible)
            root.close();
        else
            root.open();
    }

    // Dropping every level closes the menu for the application too, so the next
    // open fetches it fresh rather than showing what the app last published.
    onVisibleChanged: if (!root.visible)
        stack.clear()

    anchor {
        window: root.bar
        // Pinned to the bar window's bottom-left corner, growing up and right.
        rect.x: 0
        rect.y: root.bar !== null ? root.bar.height : 0
        rect.width: 1
        rect.height: 1
        edges: Edges.Top | Edges.Left
        gravity: Edges.Top | Edges.Right
        adjustment: PopupAdjustment.None
    }

    // Only reachable with more than one screen, where a click on another output
    // does land outside the window.
    grabFocus: true
    color: "transparent"
    implicitWidth: root.bar !== null ? root.bar.width : 0
    implicitHeight: root.bar !== null ? root.bar.screen.height : 0

    Component {
        id: level

        TrayMenuPanel {
            onDescend: (entry, label) => stack.push(level, {
                    handle: entry,
                    back: label
                })
            onAscend: stack.pop()
            onActivated: root.close()
        }
    }

    Item {
        id: field

        anchors.fill: parent

        TapHandler {
            id: outside

            // Whether the press that is in flight started on the menu. A handler
            // on an ancestor is told about taps its children already took, so
            // the menu's own area has to be excluded — and it has to be excluded
            // as of the *press*: entering a submenu resizes and moves the stack
            // before the tap is reported, which put every click outside it.
            property bool onMenu: false

            acceptedButtons: Qt.AllButtons

            onPressedChanged: {
                if (!outside.pressed)
                    return;
                const local = outside.point.position;
                outside.onMenu = local.x >= stack.x && local.x <= stack.x + stack.width && local.y >= stack.y && local.y <= stack.y + stack.height;
            }

            onSingleTapped: if (!outside.onMenu)
                root.close()
        }

        StackView {
            id: stack

            width: stack.currentItem !== null ? stack.currentItem.implicitWidth : 0
            height: stack.currentItem !== null ? stack.currentItem.implicitHeight : 0
            x: Math.max(4, Math.min(field.width - width - 4, root.targetCenter - width / 2))
            y: field.height - (root.bar !== null ? root.bar.height : 0) - height - 6

            // A menu appears where it is clicked; sliding it in would only delay
            // the row the pointer is already over.
            pushEnter: Transition {}
            pushExit: Transition {}
            popEnter: Transition {}
            popExit: Transition {}
        }
    }
}

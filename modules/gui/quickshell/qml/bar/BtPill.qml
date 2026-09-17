// Bluetooth badge: tinted when something is connected. Clicking it opens the
// device panel, which replaces blueman-applet's menu.
import QtQuick
import qs
import qs.components
import qs.services
import qs.popups

Pill {
    id: root

    visible: Bt.present
    interactive: true
    color: Bt.color
    text: Bt.glyph
    tooltip: Bt.tooltip

    onClicked: panel.toggle()

    Bluetooth {
        id: panel

        target: root
    }
}

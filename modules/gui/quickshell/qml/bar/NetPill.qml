// Network badge: signal strength, or the ethernet glyph when a cable is in.
// Clicking it opens the network panel, which replaces nm-applet's menu.
import QtQuick
import qs
import qs.components
import qs.services
import qs.popups

Pill {
    id: root

    interactive: true
    color: Net.color
    text: Net.glyph
    tooltip: Net.tooltip

    onClicked: panel.toggle()

    Networks {
        id: panel

        target: root
    }
}

// Bluetooth badge: tinted when something is connected, click or Mod+B opens
// the device panel.
import QtQuick
import qs
import qs.components
import qs.services
import qs.popups

Pill {
    id: root

    required property string monitor

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

    Connections {
        target: Bt

        function onPanelToggleRequested(): void {
            if (root.visible && root.monitor === Niri.focusedOutput)
                panel.toggle();
        }
    }
}

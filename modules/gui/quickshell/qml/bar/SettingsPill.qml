// Gear badge: tints to the active power profile, badges for active toggles.
// Hovering opens the quick-settings drawer.
import QtQuick
import qs
import qs.components
import qs.services
import qs.popups

Pill {
    id: root

    color: Quick.gearColor
    text: Quick.gearText

    QuickSettings {
        target: root
        triggerHovered: root.hovered
    }
}

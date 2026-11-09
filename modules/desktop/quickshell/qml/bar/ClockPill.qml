// Clock badge: full date+time by default, right-click flips to compact HH:mm.
// Hovering opens the two-month calendar.
import QtQuick
import Quickshell
import qs
import qs.components
import qs.services
import qs.popups

Pill {
    id: root

    property bool compact: false

    color: Theme.aqua
    text: compact ? Config.glyph.clockAlt + " " + Qt.formatDateTime(clock.date, "HH:mm") : Config.glyph.calendar + " " + Qt.formatDateTime(clock.date, "MMMM dd, HH:mm")

    onRightClicked: root.compact = !root.compact

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    Calendar {
        target: root
        triggerHovered: root.hovered
    }
}

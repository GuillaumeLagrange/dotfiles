// One bar per connected output: Variants tracks Quickshell.screens, so bars
// are created and destroyed as monitors come and go. The notification popups
// are a second surface per output rather than part of the bar window, which is
// 30px tall and has an exclusive zone.
import QtQuick
import Quickshell
import qs.bar
import qs.popups

ShellRoot {
    Variants {
        model: Quickshell.screens

        delegate: Component {
            Bar {}
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: Component {
            NotifPopups {}
        }
    }
}

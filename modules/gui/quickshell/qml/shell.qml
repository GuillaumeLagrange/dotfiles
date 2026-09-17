// One bar per connected output. Variants tracks Quickshell.screens, so bars are
// created and destroyed as monitors come and go; the eww version needed a launch
// script that queried niri for outputs and opened a window per name.
import QtQuick
import Quickshell
import qs.bar

ShellRoot {
    Variants {
        model: Quickshell.screens

        delegate: Component {
            Bar {}
        }
    }
}

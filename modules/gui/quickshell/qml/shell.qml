// One bar per connected output: Variants tracks Quickshell.screens, so bars
// are created and destroyed as monitors come and go.
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

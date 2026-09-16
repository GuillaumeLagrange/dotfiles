pragma Singleton
// Gruvbox material palette and the bar's metrics, in one place. The eww bar kept
// these in eww.scss; QML has no stylesheet, so every widget reads them here.
import QtQuick
import Quickshell

Singleton {
    readonly property color aqua: "#89B482"
    readonly property color orange: "#E78A4E"
    readonly property color blue: "#7DAEA3"
    readonly property color yellow: "#D8A657"
    readonly property color red: "#EA6962"
    readonly property color purple: "#D3869B"
    readonly property color grey: "#6C6F64"
    readonly property color green: "#A9B665"

    readonly property color barBg: "#B32B303B"
    readonly property color drawerBg: "#E62B303B"
    readonly property color border: "#1AFFFFFF"
    readonly property color fg: "#FFFFFF"
    readonly property color ink: "#1D2021"
    readonly property color track: "#3F000000"

    readonly property string mono: "Hack Nerd Font"
    readonly property string ui: "Inter"
    readonly property int fontSize: 13

    // The window is 30px tall and the bar paints the bottom 28, so tiled windows
    // stop 2px short of it instead of butting against the pills.
    readonly property int windowHeight: 30
    readonly property int barHeight: 28
    readonly property int pillHeight: 24
    readonly property int pillRadius: 4
    readonly property int pillPad: 8
    // eww gave each pill a 4px side margin, so neighbours sat 8px apart.
    readonly property int gap: 8
    readonly property int popupPad: 14

    function alpha(c: color, a: real): color {
        return Qt.rgba(c.r, c.g, c.b, a);
    }
}

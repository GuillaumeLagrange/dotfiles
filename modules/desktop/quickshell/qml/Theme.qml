pragma Singleton
// Gruvbox material palette and the bar's metrics, read by every widget.
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

    readonly property color barBg: "#D932302F"
    readonly property color drawerBg: "#F232302F"
    readonly property color border: "#1AFFFFFF"
    readonly property color fg: "#FFFFFF"
    readonly property color ink: "#1D2021"
    readonly property color track: "#3F000000"

    // Panel text and surfaces: secondary and tertiary text, row hover, and the
    // well that groups rows and holds segmented controls.
    readonly property color dim: "#73FFFFFF"
    readonly property color faint: "#40FFFFFF"
    readonly property color hoverFill: "#0FFFFFFF"
    readonly property color well: "#38000000"

    readonly property string mono: "Hack Nerd Font"
    // Nerd-font icons in the double-width Hack build have ink wider than their
    // advance, so a glyph on its own renders a fifth of an em right of centre.
    // The Propo build gives each glyph an advance that matches its ink; use it
    // wherever a Text holds nothing but glyphs.
    readonly property string icon: "Hack Nerd Font Propo"
    readonly property string ui: "Inter"
    readonly property int fontSize: 13

    // The window is 30px tall and the bar paints the bottom 28, so tiled windows
    // stop 2px short of it instead of butting against the pills.
    readonly property int windowHeight: 30
    readonly property int barHeight: 28
    readonly property int pillHeight: 24
    readonly property int pillRadius: 4
    readonly property int pillPad: 8
    // A pill's glyph and its label are separate items, so their spacing is a
    // metric rather than a space in the string.
    readonly property int glyphGap: 6
    readonly property int gap: 6
    readonly property int popupPad: 14
    // Clearance between a popup's tail tip and the pill it points at.
    readonly property int popupGap: 8
    readonly property int panelRadius: 10
    readonly property int rowRadius: 6

    function alpha(c: color, a: real): color {
        return Qt.rgba(c.r, c.g, c.b, a);
    }

    // An accent drawn as text on a panel background.
    function soften(c: color): color {
        return Qt.lighter(c, 1.12);
    }
}

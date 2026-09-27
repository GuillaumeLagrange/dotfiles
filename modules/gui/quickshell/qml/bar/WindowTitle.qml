import QtQuick
import qs
import qs.components
import qs.services

Pill {
    id: root

    required property string monitor
    readonly property string value: Niri.title(monitor)
    // Width the pill may take before it reaches the right cluster.
    property real room: 420 + hPad * 2
    readonly property int textRoom: Math.min(420, Math.floor(room - hPad * 2))

    // Below a few characters the elided title is noise.
    visible: value !== "" && textRoom >= 40
    color: Theme.aqua
    text: value
    // A pixel cap, so one long title elides instead of pushing the strip off
    // the bar.
    maxTextWidth: Math.max(1, textRoom)
    font.family: Theme.ui
}

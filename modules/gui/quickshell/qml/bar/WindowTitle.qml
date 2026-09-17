import QtQuick
import qs
import qs.components
import qs.services

Pill {
    id: root

    required property string monitor
    readonly property string value: Niri.title(monitor)

    visible: value !== ""
    color: Theme.aqua
    text: value
    // A pixel cap, so one long title elides instead of pushing the strip off
    // the bar.
    maxTextWidth: 420
    font.family: Theme.ui
}

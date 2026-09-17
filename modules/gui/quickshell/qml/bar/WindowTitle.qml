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
    // eww capped the label at 100 characters; a pixel cap elides mid-title
    // instead of letting one long title push the strip off the bar.
    maxTextWidth: 420
    font.family: Theme.ui
}

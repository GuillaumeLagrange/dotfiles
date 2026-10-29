import qs
import qs.components
import qs.services

Pill {
    text: Claude.text
    tooltip: Claude.tooltip
    interactive: true
    color: Theme.orange

    onClicked: Claude.refresh("--force-refresh")
    onRightClicked: Claude.refresh("--restart")
}

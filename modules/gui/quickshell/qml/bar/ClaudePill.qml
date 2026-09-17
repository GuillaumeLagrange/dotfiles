import qs
import qs.components
import qs.services

Pill {
    text: Claude.text
    tooltip: Claude.tooltip
    interactive: true
    color: {
        switch (Claude.cls) {
        case "critical":
            return Theme.red;
        case "high":
            return Theme.orange;
        case "mid":
            return Theme.yellow;
        default:
            return Theme.green;
        }
    }

    // Process runs are already async, so no need for eww's setsid detach dance.
    onClicked: Claude.refresh("--force-refresh")
    onRightClicked: Claude.refresh("--restart")
}

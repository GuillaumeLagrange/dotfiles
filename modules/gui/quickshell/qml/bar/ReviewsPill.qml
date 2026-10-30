// Pull requests awaiting my review; hovering lists them, clicking refreshes the
// list. The picker opens from the panel's terminal button.
import qs
import qs.components
import qs.services
import qs.popups

Pill {
    id: root

    visible: Reviews.count > 0
    interactive: true
    color: Reviews.error !== "" ? Theme.red : Theme.green
    text: `${Reviews.refreshing ? Config.glyph.refresh : Config.glyph.pullRequest} ${Reviews.count}`

    onClicked: Reviews.refresh()

    ReviewRequests {
        target: root
        triggerHovered: root.hovered
    }
}

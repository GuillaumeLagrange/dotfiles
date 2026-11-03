// Pull requests awaiting my review, counted; hovering lists them with the
// picker's other tabs, clicking refreshes the lists. The picker opens from the
// panel's terminal button.
import qs
import qs.components
import qs.services
import qs.popups

Pill {
    id: root

    // Up while any tab lists something, so my own PRs stay reachable with no review asked of me.
    visible: Reviews.count > 0 || Reviews.reviewed.count > 0 || Reviews.mine.count > 0
    interactive: true
    color: Reviews.error !== "" ? Theme.red : Reviews.count > 0 ? Theme.green : Theme.grey
    text: `${Reviews.refreshing ? Config.glyph.refresh : Config.glyph.pullRequest} ${Reviews.count}`

    onClicked: Reviews.refresh()

    ReviewRequests {
        target: root
        triggerHovered: root.hovered
    }
}

// Pull requests awaiting my review, counted; clicking lists them with the
// picker's other tabs. The panel's buttons refresh the lists and open the picker.
import qs
import qs.components
import qs.services
import qs.popups

Pill {
    id: root

    // Up while any tab lists something, so my own PRs stay reachable with no review asked of me.
    // Read by the bar's Loader: `visible` would follow the Loader's own.
    readonly property bool shown: Reviews.count > 0 || Reviews.reviewed.count > 0 || Reviews.mine.count > 0
    visible: shown
    interactive: true
    color: Reviews.error !== "" ? Theme.red : Reviews.count > 0 ? Theme.green : Theme.grey
    text: `${Reviews.refreshing ? Config.glyph.refresh : Config.glyph.pullRequest} ${Reviews.count}`

    onClicked: panel.toggle()

    ReviewRequests {
        id: panel

        target: root
    }
}

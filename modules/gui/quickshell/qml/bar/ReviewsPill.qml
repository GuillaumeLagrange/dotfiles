// Pull requests awaiting my review; hovering lists them, clicking opens the picker.
import Quickshell
import qs
import qs.components
import qs.services
import qs.popups

Pill {
    id: root

    visible: Reviews.count > 0
    interactive: true
    color: Theme.green
    text: `${Config.glyph.pullRequest} ${Reviews.count}`

    onClicked: {
        panel.close();
        Quickshell.execDetached(Config.review);
    }

    ReviewRequests {
        id: panel

        target: root
        triggerHovered: root.hovered
    }
}

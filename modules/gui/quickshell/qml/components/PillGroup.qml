// Pills that belong together drawn as one block: no gaps inside, and only the
// outer corners of the run are rounded, so the group reads as a single control
// with coloured segments.
import QtQuick
import qs

Row {
    id: root

    spacing: 0

    function shape(): void {
        const pills = Array.prototype.filter.call(root.children, c => c.visible);
        for (let i = 0; i < pills.length; i++) {
            const left = i === 0 ? Theme.pillRadius : 0;
            const right = i === pills.length - 1 ? Theme.pillRadius : 0;
            pills[i].topLeftRadius = pills[i].bottomLeftRadius = left;
            pills[i].topRightRadius = pills[i].bottomRightRadius = right;
        }
    }

    Component.onCompleted: {
        // A pill that comes and goes (no bluetooth adapter, nothing recording)
        // changes which ones are on the ends.
        for (const child of root.children)
            child.visibleChanged.connect(root.shape);
        root.shape();
    }
}

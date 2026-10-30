// What was typed into a panel's list: a fuzzy filter over its rows' names,
// best match first, shown while there is one.
import QtQuick
import QtQuick.Layouts
import qs

RowLayout {
    id: root

    property string query: ""
    property color accent: Theme.blue
    // Whether the filter left the list empty.
    property bool empty: false

    // Lower is better; null when the text lacks the query's characters in
    // order. Gaps cost, landing on a word or camel-case start pays, and each
    // start of the first character is tried, so "ap" puts AirPods ahead of
    // the a and p of "Arctis Nova Pro".
    function score(text: string): var {
        const q = root.query.toLowerCase();
        const hay = text.toLowerCase();
        const boundary = i => i === 0 || !/[a-z0-9]/i.test(text[i - 1]) || (text[i] !== hay[i] && text[i - 1] === hay[i - 1]);
        let best = null;
        for (let start = hay.indexOf(q[0]); start >= 0; start = hay.indexOf(q[0], start + 1)) {
            let at = start;
            let cost = start / 10 - (boundary(start) ? 3 : 0);
            for (let k = 1; k < q.length; k++) {
                const next = hay.indexOf(q[k], at + 1);
                if (next < 0)
                    return best;
                cost += next - at - 1 - (boundary(next) ? 3 : 0);
                at = next;
            }
            if (best === null || cost < best)
                best = cost;
        }
        return best;
    }

    // The items whose name matches, best first; all of them, in order, without a query.
    function filter(items: var, name: var): var {
        if (root.query === "")
            return items;
        return items.map((item, i) => ({
                    item,
                    i,
                    s: root.score(name(item))
                })).filter(e => e.s !== null).sort((a, b) => a.s - b.s || a.i - b.i).map(e => e.item);
    }

    // Edits the query from a list's key press; false when the key is not typing.
    function type(event: var): bool {
        if (event.key === Qt.Key_Backspace) {
            if (root.query === "")
                return false;
            root.query = root.query.slice(0, -1);
            return true;
        }
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
            return false;
        if (event.text === "" || event.text < " " || event.text === "\u007f")
            return false;
        root.query += event.text;
        return true;
    }

    Layout.fillWidth: true
    Layout.leftMargin: 8
    Layout.rightMargin: 8
    visible: root.query !== ""
    spacing: 8

    Text {
        text: Config.glyph.search
        color: Theme.soften(root.accent)
        font.family: Theme.icon
        font.pixelSize: 12
    }

    Text {
        Layout.fillWidth: true
        text: root.query
        elide: Text.ElideLeft
        color: Theme.fg
        font.family: Theme.ui
        font.pixelSize: 12
    }

    Text {
        visible: root.empty
        text: "no match"
        color: Theme.faint
        font.family: Theme.ui
        font.pixelSize: 10
    }
}

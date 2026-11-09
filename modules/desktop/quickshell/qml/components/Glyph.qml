// A glyph centred on its ink rather than on its font metrics.
//
// Centring a Text centres the line box: the ascent, descent and side bearings
// the font declares, which for nerd-font icons have little to do with where
// the drawn shape sits. The ink box is what to centre on - no per-glyph
// nudging, and it stays right when a glyph or the font changes.
//
// Vertical bounds come from `Config.glyphInk` where Qt is wrong: its
// `tightBoundingRect` clamps the box to the baseline, so a glyph drawn wholly
// above it (the tray's three dots) reports a box stretched down to the
// baseline and lands too high.
import QtQuick
import qs

Item {
    id: root

    property string text: ""
    property color color: Theme.fg
    property string family: Theme.icon
    property int size: Theme.fontSize

    readonly property rect qtInk: metrics.tightBoundingRect
    // Ink top and bottom in Qt's coordinates (negative is above the baseline).
    // A codepoint the table knows replaces Qt's answer rather than widening it:
    // Qt's box is the wrong one, and it is the larger of the two. Qt still
    // answers for a string whose codepoints are not all in the table.
    readonly property var bounds: {
        let top = Infinity;
        let bottom = -Infinity;
        let known = 0;
        let count = 0;
        for (let i = 0; i < root.text.length; count++) {
            const cp = root.text.codePointAt(i);
            i += cp > 0xFFFF ? 2 : 1;
            const em = Config.glyphInk[cp.toString(16)];
            if (!em)
                continue;
            known++;
            top = Math.min(top, -em[1] * root.size);
            bottom = Math.max(bottom, -em[0] * root.size);
        }
        if (known === 0 || known < count) {
            top = Math.min(top, root.qtInk.y);
            bottom = Math.max(bottom, root.qtInk.y + root.qtInk.height);
        }
        return [top, bottom];
    }

    // Whole pixels: a glyph on a half pixel is blurred by the renderer and
    // reads as misaligned next to crisp text.
    readonly property int inkTop: Math.floor(root.bounds[0])
    readonly property int inkLeft: Math.floor(root.qtInk.x)

    implicitWidth: Math.ceil(root.qtInk.x + root.qtInk.width) - root.inkLeft
    implicitHeight: Math.ceil(root.bounds[1]) - root.inkTop

    Text {
        id: label

        // Ink bounds are measured from the text origin, which sits on the
        // baseline; a Text item's own origin is the top of the line box.
        x: -root.inkLeft
        y: -root.inkTop - Math.round(label.baselineOffset)
        text: root.text
        color: root.color
        font.family: root.family
        font.pixelSize: root.size
    }

    TextMetrics {
        id: metrics

        font: label.font
        text: root.text
    }
}

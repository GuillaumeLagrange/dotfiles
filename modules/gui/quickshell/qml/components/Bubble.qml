// Comic-book speech bubble: a rounded body with a tail hanging off its bottom
// edge, pointing at whatever opened it.
//
// Body and tail are one closed path rather than a rectangle plus a triangle,
// because the drawer background is translucent: two overlapping shapes would
// double their alpha along the seam and the border would draw a line straight
// across the body.
import QtQuick
import QtQuick.Shapes
import qs

Shape {
    id: root

    property real bodyRadius: 8
    property real tailWidth: 14
    property real tailHeight: 7
    // Where the tip lands, in this item's coordinates.
    property real tailX: width / 2
    property color fill: Theme.drawerBg
    property color stroke: Theme.border

    readonly property real bodyHeight: height - tailHeight
    // The tail leaves from the flat part of the bottom edge, so it cannot cut
    // into a corner arc when the panel is slid back from a screen edge.
    readonly property real tailCenter: Math.max(bodyRadius + tailWidth, Math.min(width - bodyRadius - tailWidth, tailX))

    // Antialiases without a multisampled window, which a layer surface is not.
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
        fillColor: root.fill
        strokeColor: root.stroke
        strokeWidth: 1
        joinStyle: ShapePath.RoundJoin

        startX: root.bodyRadius
        startY: 0.5

        PathLine {
            x: root.width - root.bodyRadius
            y: 0.5
        }
        PathArc {
            x: root.width - 0.5
            y: root.bodyRadius
            radiusX: root.bodyRadius
            radiusY: root.bodyRadius
            direction: PathArc.Clockwise
        }
        PathLine {
            x: root.width - 0.5
            y: root.bodyHeight - root.bodyRadius
        }
        PathArc {
            x: root.width - root.bodyRadius
            y: root.bodyHeight
            radiusX: root.bodyRadius
            radiusY: root.bodyRadius
            direction: PathArc.Clockwise
        }
        PathLine {
            x: root.tailCenter + root.tailWidth / 2
            y: root.bodyHeight
        }
        PathLine {
            x: root.tailCenter
            y: root.height - 0.5
        }
        PathLine {
            x: root.tailCenter - root.tailWidth / 2
            y: root.bodyHeight
        }
        PathLine {
            x: root.bodyRadius
            y: root.bodyHeight
        }
        PathArc {
            x: 0.5
            y: root.bodyHeight - root.bodyRadius
            radiusX: root.bodyRadius
            radiusY: root.bodyRadius
            direction: PathArc.Clockwise
        }
        PathLine {
            x: 0.5
            y: root.bodyRadius
        }
        PathArc {
            x: root.bodyRadius
            y: 0.5
            radiusX: root.bodyRadius
            radiusY: root.bodyRadius
            direction: PathArc.Clockwise
        }
    }
}

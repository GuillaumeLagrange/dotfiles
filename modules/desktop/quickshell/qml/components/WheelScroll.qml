// Wheel and touchpad scrolling for a vertical Flickable, as a browser does it.
// Qt's own turns every wheel notch into a flick with its deceleration and
// bounces at the ends. Here a touchpad moves the content by exactly its pixels,
// then glides on when the fingers lift; a wheel notch eases a fixed step, and
// notches in quick succession add up. Qt's Wayland plugin gives a wheel a
// pixelDelta too (the compositor's 15 per notch), so the two are told apart by
// the scroll phase, which only finger scrolling has.
import QtQuick

WheelHandler {
    id: root

    required property Flickable flickable
    // Pixels per wheel notch.
    property real step: 90

    // Recent touchpad deltas, for the speed it is left with.
    property var samples: []

    function clamp(y: real): real {
        const f = root.flickable;
        return Math.max(f.originY, Math.min(f.originY + Math.max(0, f.contentHeight - f.height), y));
    }

    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

    onWheel: event => {
        const f = root.flickable;
        const now = Date.now();
        if (event.phase !== Qt.NoScrollPhase) {
            ease.stop();
            f.cancelFlick();
            if (event.phase === Qt.ScrollEnd) {
                const recent = root.samples.filter(s => now - s.t < 80);
                root.samples = [];
                if (recent.length > 1) {
                    const span = Math.max(16, now - recent[0].t);
                    const moved = recent.reduce((sum, s) => sum + s.dy, 0);
                    // A positive velocity moves the content down, as the delta does.
                    f.flick(0, moved / span * 1000);
                }
                return;
            }
            if (event.pixelDelta.y === 0)
                return;
            root.samples = root.samples.filter(s => now - s.t < 80).concat([
                {
                    t: now,
                    dy: event.pixelDelta.y
                }
            ]);
            f.contentY = root.clamp(f.contentY - event.pixelDelta.y);
        } else if (event.angleDelta.y !== 0) {
            f.cancelFlick();
            const from = ease.running ? ease.to : f.contentY;
            ease.stop();
            ease.from = f.contentY;
            ease.to = root.clamp(from - event.angleDelta.y / 120 * root.step);
            ease.start();
        }
    }

    property NumberAnimation ease: NumberAnimation {
        target: root.flickable
        property: "contentY"
        duration: 180
        easing.type: Easing.OutCubic
    }
}

import QtQuick
import qs
import qs.components
import qs.services

Pill {
    id: root

    visible: Yubikey.waiting
    color: Theme.yellow
    text: `${Config.glyph.fingerprint} Touch`
    tooltip: `YubiKey waiting for a touch (${Yubikey.kinds})`

    SequentialAnimation on opacity {
        running: root.visible
        loops: Animation.Infinite
        onStopped: root.opacity = 1

        NumberAnimation {
            to: 0.45
            duration: 600
            easing.type: Easing.InOutSine
        }

        NumberAnimation {
            to: 1
            duration: 600
            easing.type: Easing.InOutSine
        }
    }
}

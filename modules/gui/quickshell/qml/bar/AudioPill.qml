// Default sink volume: click opens the audio panel, scroll changes it.
import QtQuick
import qs
import qs.components
import qs.services
import qs.popups

Pill {
    id: root

    interactive: true
    color: Audio.color
    text: `${Audio.glyph} ${Audio.volume}%`
    tooltip: Audio.tooltip

    onClicked: panel.toggle()
    onRightClicked: Audio.toggleMute(Audio.sink)
    onScrolled: dy => Audio.setVolume(Audio.sink, (Audio.sink?.audio?.volume ?? 0) + (dy > 0 ? 0.02 : -0.02))

    Volume {
        id: panel

        target: root
    }
}

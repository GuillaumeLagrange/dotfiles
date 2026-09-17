// Default sink volume, straight from Pipewire. Clicking opens the audio panel,
// which is what pavucontrol used to be launched for; scrolling still works on
// the pill itself.
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

// Default sink volume and mute state, straight from Pipewire: no `wpctl` poll,
// no `pactl subscribe` tail.
import Quickshell
import Quickshell.Services.Pipewire
import qs
import qs.components

Pill {
    id: root

    readonly property PwNode sink: Pipewire.defaultAudioSink
    readonly property PwNodeAudio audio: sink ? sink.audio : null
    readonly property int pct: audio ? Math.round(audio.volume * 100) : 0
    readonly property bool muted: audio ? audio.muted : false

    color: muted ? Theme.grey : Theme.orange
    text: `${muted ? Config.glyph.volMuted : pct < 34 ? Config.glyph.volLow : pct < 67 ? Config.glyph.volMid : Config.glyph.volHigh} ${pct}%`
    tooltip: sink ? (sink.description || sink.nickname || sink.name) : "Default sink"

    onClicked: Quickshell.execDetached([Config.pavucontrol])

    onScrolled: dy => {
        if (!audio)
            return;
        audio.muted = false;
        audio.volume = Math.max(0, Math.min(1, audio.volume + (dy > 0 ? 0.01 : -0.01)));
    }

    // Node properties are only tracked while something holds the object.
    PwObjectTracker {
        objects: root.sink ? [root.sink] : []
    }
}

pragma Singleton
// Pipewire's graph: the output and input devices, the default of each, and
// the per-application streams.
import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import qs

Singleton {
    id: root

    readonly property var nodes: Pipewire.nodes.values

    // Node type flags: a sink is Audio|Sink, a source Audio|Source, a playback
    // stream Audio|Stream|Sink. `isStream` is what separates a device from an
    // application's stream on the same side of the graph.
    readonly property var sinks: root.nodes.filter(node => node.audio && node.isSink && !node.isStream).sort((a, b) => root.label(a).localeCompare(root.label(b)))
    readonly property var sources: root.nodes.filter(node => node.audio && !node.isSink && !node.isStream).sort((a, b) => root.label(a).localeCompare(root.label(b)))
    readonly property var streams: root.nodes.filter(node => node.audio && node.isStream && node.isSink && !root.isNotification(node))

    readonly property PwNode sink: Pipewire.defaultAudioSink
    readonly property PwNode source: Pipewire.defaultAudioSource

    // Held rather than bound: a node's data is momentarily unpopulated while
    // quickshell rebinds the tracked set, and a read in that window would
    // render the pill's default instead of the volume.
    property int volume: 0
    property bool muted: false

    // -1 when the sink has no readable audio object.
    readonly property int liveVolume: root.sink?.audio ? Math.round(root.sink.audio.volume * 100) : -1
    readonly property int liveMuted: root.sink?.audio ? (root.sink.audio.muted ? 1 : 0) : -1

    onLiveVolumeChanged: if (root.liveVolume >= 0)
        root.volume = root.liveVolume
    onLiveMutedChanged: if (root.liveMuted >= 0)
        root.muted = root.liveMuted === 1

    // Event sounds are blips, not something playing: the volume-key feedback
    // would otherwise flash a row of its own on every press. Its properties
    // are often still empty in the instant it exists, so the node's own name
    // is checked too - that one is always there.
    readonly property var blipNames: ["paplay", "pw-play", "pw-cat", "canberra-gtk-play", "speech-dispatcher"]

    function isNotification(node): bool {
        const role = (node.properties["media.role"] ?? "").toLowerCase();
        if (role === "notification" || role === "event")
            return true;
        return root.blipNames.includes((node.name ?? "").toLowerCase());
    }

    function label(node): string {
        if (!node)
            return "";
        return node.description || node.nickname || node.name;
    }

    // A stream is named by its application; `media.name` is the track or tab,
    // which is the useful second line.
    function appName(node): string {
        const app = node.properties["application.name"] ?? "";
        if (app === "")
            return root.label(node);
        return app.charAt(0).toUpperCase() + app.slice(1);
    }

    function streamTitle(node): string {
        const media = node.properties["media.name"] ?? "";
        return media === root.appName(node) ? "" : media;
    }

    function setVolume(node, value: real): void {
        if (!node?.audio)
            return;
        node.audio.muted = false;
        node.audio.volume = Math.max(0, Math.min(1, value));
    }

    function toggleMute(node): void {
        if (node?.audio)
            node.audio.muted = !node.audio.muted;
    }

    function setSink(node): void {
        Pipewire.preferredDefaultAudioSink = node;
    }

    function setSource(node): void {
        Pipewire.preferredDefaultAudioSource = node;
    }

    function volumeGlyph(level: int, off: bool): string {
        if (off)
            return Config.glyph.volMuted;
        return level < 34 ? Config.glyph.volLow : Config.glyph.volHigh;
    }

    readonly property string glyph: root.volumeGlyph(root.volume, root.muted)
    readonly property color color: root.muted ? Theme.grey : Theme.orange

    readonly property string tooltip: {
        const device = root.label(root.sink) || "No output";
        const playing = root.streams.map(stream => root.appName(stream)).join(", ");
        return playing === "" ? device : `${device} - ${playing}`;
    }

    // Volumes and mute states are only tracked while something holds the node,
    // and the panel needs every one of them, not just the default sink's.
    PwObjectTracker {
        objects: root.nodes
    }
}

pragma Singleton
// BlueZ through quickshell's own client: the adapter switch, the paired
// devices, and their batteries.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import qs

Singleton {
    id: root

    readonly property BluetoothAdapter adapter: Bluetooth.defaultAdapter
    readonly property bool present: root.adapter !== null
    readonly property bool enabled: root.present && root.adapter.enabled
    readonly property bool discovering: root.present && root.adapter.discovering

    // Connected first, then remembered, then whatever the scan turned up; each
    // group by name so the list does not reshuffle as signal strengths move.
    // A scan hit with no advertised name (BlueZ then aliases it to its address)
    // is one of the anonymous LE beacons around and is left out.
    readonly property var devices: {
        if (!root.present)
            return [];
        const known = dev => dev.paired || dev.bonded;
        const rank = dev => dev.connected ? 0 : (known(dev) ? 1 : 2);
        return root.adapter.devices.values.filter(dev => known(dev) || dev.connected || dev.deviceName !== "").sort((a, b) => {
            if (rank(a) !== rank(b))
                return rank(a) - rank(b);
            return (a.name || a.address).localeCompare(b.name || b.address);
        });
    }

    readonly property var connectedDevices: root.devices.filter(dev => dev.connected)

    // Pairing runs `bt-pair` rather than the device's pair(): see bt-pair.py.
    property var pairingDevice: null
    property string pairError: ""

    function pair(dev) {
        root.pairError = "";
        root.pairingDevice = dev;
        pairer.command = [Config.btPair, dev.dbusPath];
        pairer.running = true;
    }

    function cancelPair() {
        pairer.running = false;
    }

    Process {
        id: pairer

        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "")
                root.pairError = text.trim().split("\n").pop()
        }

        onExited: root.pairingDevice = null
    }

    // BlueZ reports a freedesktop icon name; the bar draws nerd-font glyphs.
    // Returns a key of Config.glyph.
    function bluezGlyphKey(dev): string {
        const icon = dev?.icon ?? "";
        if (icon.includes("headset") || icon.includes("headphone"))
            return "headphones";
        if (icon.includes("audio") || icon.includes("speaker"))
            return "speaker";
        if (icon.includes("mouse"))
            return "mouse";
        if (icon.includes("keyboard"))
            return "keyboard";
        if (icon.includes("phone"))
            return "phone";
        if (icon.includes("watch"))
            return "watch";
        if (icon.includes("gaming") || icon.includes("gamepad"))
            return "gamepad";
        if (icon.includes("computer"))
            return "device";
        return "bluetooth";
    }

    // Glyph keys picked in the panel, by device address.
    property var glyphOverrides: ({})

    function glyphKey(dev): string {
        return root.glyphOverrides[dev?.address ?? ""] ?? root.bluezGlyphKey(dev);
    }

    function deviceGlyph(dev): string {
        return Config.glyph[root.glyphKey(dev)] ?? Config.glyph.bluetooth;
    }

    // Picking BlueZ's own glyph drops the override.
    function setGlyph(dev, key: string) {
        const overrides = Object.assign({}, root.glyphOverrides);
        if (key === root.bluezGlyphKey(dev))
            delete overrides[dev.address];
        else
            overrides[dev.address] = key;
        root.glyphOverrides = overrides;
        overridesFile.setText(JSON.stringify(overrides, null, 2) + "\n");
    }

    FileView {
        id: overridesFile

        path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/quickshell/bt-glyphs.json"
        printErrors: false
        onLoaded: {
            try {
                root.glyphOverrides = JSON.parse(overridesFile.text());
            } catch (e) {
                // Keep the last good state.
            }
        }
    }

    function batteryOf(dev): string {
        return dev?.batteryAvailable ? `${Math.round(dev.battery * 100)}%` : "";
    }

    readonly property string glyph: {
        if (!root.enabled)
            return Config.glyph.bluetoothOff;
        return root.connectedDevices.length > 0 ? Config.glyph.bluetoothOn : Config.glyph.bluetooth;
    }

    readonly property color color: {
        if (!root.enabled)
            return Theme.grey;
        return root.connectedDevices.length > 0 ? Theme.blue : Theme.alpha(Theme.blue, 0.55);
    }

    readonly property string tooltip: {
        if (!root.present)
            return "No Bluetooth adapter";
        if (!root.enabled)
            return "Bluetooth off";
        if (root.connectedDevices.length === 0)
            return "Bluetooth on, nothing connected";
        return root.connectedDevices.map(dev => {
            const battery = root.batteryOf(dev);
            return battery === "" ? dev.name : `${dev.name} (${battery})`;
        }).join(", ");
    }

    // Asked for from the panel, never implied by opening it: discovery is a
    // radio duty cycle that stutters A2DP, and the devices worth connecting to
    // are the paired ones, which are listed whether or not the radio sweeps.
    property bool scanning: false

    Binding {
        target: root.adapter
        property: "discovering"
        value: root.scanning && root.enabled
        when: root.present
    }

    // Mod+B reaches every bar; the one on the focused output answers.
    signal panelToggleRequested

    IpcHandler {
        target: "bt"

        function panel(): void {
            root.panelToggleRequested();
        }
    }
}

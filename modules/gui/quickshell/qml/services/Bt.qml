pragma Singleton
// BlueZ through quickshell's own client: the adapter switch, the paired
// devices, and their batteries.
import QtQuick
import Quickshell
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
    readonly property var devices: {
        if (!root.present)
            return [];
        const rank = dev => dev.connected ? 0 : (dev.paired || dev.bonded ? 1 : 2);
        return root.adapter.devices.values.slice().sort((a, b) => {
            if (rank(a) !== rank(b))
                return rank(a) - rank(b);
            return (a.name || a.address).localeCompare(b.name || b.address);
        });
    }

    readonly property var connectedDevices: root.devices.filter(dev => dev.connected)

    // BlueZ reports a freedesktop icon name; the bar draws nerd-font glyphs.
    function deviceGlyph(dev): string {
        const icon = dev.icon ?? "";
        if (icon.includes("headset") || icon.includes("headphone"))
            return Config.glyph.headphones;
        if (icon.includes("audio") || icon.includes("speaker"))
            return Config.glyph.speaker;
        if (icon.includes("mouse"))
            return Config.glyph.mouse;
        if (icon.includes("keyboard"))
            return Config.glyph.keyboard;
        if (icon.includes("phone"))
            return Config.glyph.phone;
        if (icon.includes("watch"))
            return Config.glyph.watch;
        if (icon.includes("gaming") || icon.includes("gamepad"))
            return Config.glyph.gamepad;
        if (icon.includes("computer"))
            return Config.glyph.device;
        return Config.glyph.bluetooth;
    }

    function batteryOf(dev): string {
        return dev.batteryAvailable ? `${Math.round(dev.battery * 100)}%` : "";
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
}

// Battery badge, from UPower. Hidden on a machine with no laptop battery.
import Quickshell.Services.UPower
import qs
import qs.components

Pill {
    id: root

    readonly property var device: UPower.displayDevice
    readonly property bool present: device.isLaptopBattery
    readonly property bool charging: device.state === UPowerDeviceState.Charging || device.state === UPowerDeviceState.FullyCharged
    // UPower reports the charge level as a 0-1 fraction.
    readonly property int percentage: Math.round(device.percentage * 100)
    readonly property bool critical: !charging && percentage <= 15
    readonly property string glyph: charging ? Config.glyph.batCharging : percentage >= 67 ? Config.glyph.batHigh : percentage >= 34 ? Config.glyph.batMedium : Config.glyph.batLow

    function _eta(seconds: real, label: string): string {
        if (!(seconds > 0))
            return "";
        const mins = Math.floor(seconds / 60);
        const h = Math.floor(mins / 60);
        const m = mins % 60;
        return `${h}h${String(m).padStart(2, "0")}m ${label}`;
    }

    visible: present
    color: charging ? Theme.green : critical ? Theme.red : Theme.fg
    text: `${glyph} ${percentage}%`
    tooltip: {
        const eta = charging ? _eta(device.timeToFull, "until full") : _eta(device.timeToEmpty, "remaining");
        const base = `Battery ${percentage}% \u2014 ${UPowerDeviceState.toString(device.state)}`;
        return eta ? `${base}\n${eta}` : base;
    }
}

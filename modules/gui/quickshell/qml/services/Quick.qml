pragma Singleton
// Quick-settings state: power profile and idle inhibit. Do-not-disturb is the
// notification server's own (services/Notifs.qml).
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs

Singleton {
    id: root

    readonly property string profileName: {
        if (PowerProfiles.profile === PowerProfile.PowerSaver)
            return "power-saver";
        if (PowerProfiles.profile === PowerProfile.Performance)
            return "performance";
        if (PowerProfiles.profile === PowerProfile.Balanced)
            return "balanced";
        return "unknown";
    }

    readonly property color gearColor: {
        if (root.profileName === "performance")
            return Theme.red;
        if (root.profileName === "balanced")
            return Theme.blue;
        if (root.profileName === "power-saver")
            return Theme.green;
        return Theme.grey;
    }

    function setProfile(name: string): void {
        if (name === "power-saver")
            PowerProfiles.profile = PowerProfile.PowerSaver;
        else if (name === "performance")
            PowerProfiles.profile = PowerProfile.Performance;
        else if (name === "balanced")
            PowerProfiles.profile = PowerProfile.Balanced;
    }

    // The Wayland idle-inhibit protocol only blocks the compositor's own idle
    // timeout, not logind's suspend-then-hibernate; a held systemd idle lock
    // blocks both. The held Process is itself the lock, so it is released on
    // every shell start and there is no pidfile to go stale.
    property bool idleInhibit: false

    function toggleIdle(): void {
        root.idleInhibit = !root.idleInhibit;
    }

    Process {
        running: root.idleInhibit
        command: [Config.systemdInhibit, "--what=idle", "--who=quickshell-bar", "--why=Idle inhibited from bar", "--mode=block", Config.sleepBin, "infinity"]
    }
}

pragma Singleton
// Quick-settings state: power profile, idle inhibit and caffeine.
// Do-not-disturb is the notification server's own (services/Notifs.qml).
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

    // Caffeine is granary's system caffeine.service (hosts/granary/caffeine.nix).
    // The bar only picks a mode in a file; the caffeine-auto user service starts
    // and stops the unit from it, and the unit keeps /run/caffeine/active at 1
    // while it runs. `caffeine` is that file, so on means lid close will not
    // suspend. Both files are watched; the row is hidden where the unit's file is missing.
    property bool caffeineAvailable: false
    property bool caffeine: false
    property string caffeineMode: "auto"

    function setCaffeineMode(mode: string): void {
        root.caffeineMode = mode;
        caffeineModeFile.setText(mode);
    }

    FileView {
        id: caffeineModeFile

        path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/caffeine/mode"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const mode = caffeineModeFile.text().trim();
            root.caffeineMode = mode === "off" || mode === "on" ? mode : "auto";
        }
    }

    FileView {
        id: caffeineActiveFile

        path: "/run/caffeine/active"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            root.caffeineAvailable = true;
            root.caffeine = caffeineActiveFile.text().trim() === "1";
        }
        onLoadFailed: {
            root.caffeineAvailable = false;
            root.caffeine = false;
        }
    }
}

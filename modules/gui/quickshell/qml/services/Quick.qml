pragma Singleton
// Quick-settings state: power profile, idle inhibit, do-not-disturb. settings.sh
// polled/pushed all three from a bash script plus a gdbus watcher; the profile
// now lives in UPower's own live-tracked service, and idle/dnd need only a
// held process and one makoctl query each.
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
    // blocks both (see the old idle-inhibit.sh). Starts released on every shell
    // start, same as the eww-idle-reset unit achieved, and the held Process
    // itself *is* the lock, so there is no pidfile to go stale.
    property bool idleInhibit: false

    function toggleIdle(): void {
        root.idleInhibit = !root.idleInhibit;
    }

    Process {
        running: root.idleInhibit
        command: [Config.systemdInhibit, "--what=idle", "--who=quickshell-bar", "--why=Idle inhibited from bar", "--mode=block", Config.sleepBin, "infinity"]
    }

    property bool dndOn: false

    function toggleDnd(): void {
        dndToggle.running = true;
    }

    // Seeds dndOn at singleton creation (like Niri's tap), then re-queried
    // after every toggle.
    Process {
        id: dndQuery

        command: [Config.makoctl, "mode"]
        running: true

        stdout: StdioCollector {
            onStreamFinished: root.dndOn = text.includes("do-not-disturb")
        }
    }

    Process {
        id: dndToggle

        command: [Config.makoctl, "mode", "-t", "do-not-disturb"]
        onExited: dndQuery.running = true
    }

    readonly property string gearText: {
        const badges = [];
        if (root.idleInhibit)
            badges.push(Config.glyph.idle);
        if (root.dndOn)
            badges.push(Config.glyph.dnd);
        return badges.length > 0 ? badges.join(" ") + " " + Config.glyph.gear : Config.glyph.gear;
    }
}

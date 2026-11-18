// Spliced into the test copy's ControlPill: `qs ipc call controlcenter state`
// prints the focused output's control centre: open, focused, and the display
// setup Mod+M preselected.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

Item {
    id: probe

    required property Item pill
    required property var panel

    IpcHandler {
        target: "controlcenter"
        enabled: probe.pill.monitor === Niri.focusedOutput

        function state(): string {
            return JSON.stringify({
                open: probe.panel.visible,
                focused: probe.panel.contentItem.Window.active,
                cursor: probe.panel.probeDisplays.cursor
            });
        }
    }
}

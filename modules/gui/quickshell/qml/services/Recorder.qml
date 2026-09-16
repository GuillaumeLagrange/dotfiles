pragma Singleton
// Screen-recording state. The recorder is started from niri keybinds and from
// the bar, so the state is pushed in from screen-tools.nix rather than polled:
//   qs -c bar ipc call recorder set true "<label>"
import Quickshell
import Quickshell.Io
import qs

Singleton {
    id: root

    property bool recording: false
    property string text: ""

    function toggle(): void {
        Quickshell.execDetached([Config.screenrecord]);
    }

    IpcHandler {
        target: "recorder"

        function set(recording: string, text: string): void {
            root.recording = recording === "true";
            root.text = text;
        }
    }
}

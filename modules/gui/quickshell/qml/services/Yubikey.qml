pragma Singleton
// Whether the YubiKey is blinking for a touch, from yubikey-touch-detector's
// socket (socket-activated, see default.nix). Events are bare 5-byte words
// (GPG_1, U2F_0, MAC_1...) with no delimiter, so reads are buffered and cut by
// length. Nothing is replayed on connect: the state starts idle.
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property var pending: ({
            GPG: false,
            U2F: false,
            MAC: false
        })
    readonly property bool waiting: pending.GPG || pending.U2F || pending.MAC
    readonly property string kinds: ["GPG", "U2F", "MAC"].filter(k => pending[k]).map(k => k === "MAC" ? "HMAC" : k).join(", ")

    property string buffer: ""

    Socket {
        id: socket

        path: `${Quickshell.env("XDG_RUNTIME_DIR")}/yubikey-touch-detector.socket`
        connected: true
        // A failed connect sets no state, so only the timer retries it.
        onError: if (!connected)
            retry.start()
        onConnectedChanged: {
            if (connected)
                return;
            // A dropped connection loses the 0 that would have cleared a wait.
            root.pending = {
                GPG: false,
                U2F: false,
                MAC: false
            };
            root.buffer = "";
            retry.start();
        }

        parser: SplitParser {
            splitMarker: ""
            onRead: data => {
                let buf = root.buffer + data;
                const next = Object.assign({}, root.pending);
                while (buf.length >= 5) {
                    const kind = buf.slice(0, 3);
                    if (kind in next)
                        next[kind] = buf[4] === "1";
                    buf = buf.slice(5);
                }
                root.buffer = buf;
                root.pending = next;
            }
        }
    }

    Timer {
        id: retry

        interval: 5000
        onTriggered: socket.connected = true
    }
}

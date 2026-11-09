pragma Singleton
// Saved display setups (pkgs/niri-displays): the control centre lists them,
// applies one, saves the current layout under a name and deletes. Read when the
// panel opens and after each change; nothing else here needs them live.
import QtQuick
import Quickshell
import Quickshell.Io
import qs

Singleton {
    id: root

    property var setups: []
    // The connected monitors' setups first, then the others.
    readonly property var ordered: root.setups.filter(s => s.fits).concat(root.setups.filter(s => !s.fits))
    readonly property bool anyFits: root.setups.some(s => s.fits)
    property string error: ""
    property bool _again: false

    function refresh(): void {
        if (list.running)
            root._again = true;
        else
            list.running = true;
    }

    function apply(name: string): void {
        root._run(["apply", name]);
    }

    function save(name: string): void {
        root._run(["save", name]);
    }

    function remove(name: string): void {
        root._run(["delete", name]);
    }

    function rename(old: string, name: string): void {
        root._run(["rename", old, name]);
    }

    // Shown at once, so a dropped card does not jump back until the list is read again.
    function order(names: var): void {
        root.setups = names.map(n => root.setups.find(s => s.name === n)).filter(s => !!s);
        root._run(["order"].concat(names));
    }

    function has(name: string): bool {
        return root.setups.some(s => s.name === name.trim());
    }

    function _run(args: var): void {
        root.error = "";
        const proc = act.createObject(root, {
            command: [Config.niriDisplays].concat(args)
        });
        proc.running = true;
    }

    Component {
        id: act

        Process {
            id: proc

            stderr: StdioCollector {
                id: err
            }
            onExited: code => {
                if (code !== 0)
                    root.error = err.text.trim().split("\n").pop() || "niri-displays failed";
                root.refresh();
                proc.destroy();
            }
        }
    }

    Process {
        id: list

        command: [Config.niriDisplays, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.setups = JSON.parse(this.text).setups;
                } catch (e) {
                    root.setups = [];
                }
            }
        }
        onExited: if (root._again) {
            root._again = false;
            list.running = true;
        }
    }
}

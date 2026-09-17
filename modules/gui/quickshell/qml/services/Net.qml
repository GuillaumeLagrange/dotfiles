pragma Singleton
// NetworkManager state, read through quickshell's own NM client. nm-applet was
// in the tray only to carry this, and its menu was the only way to pick a
// network.
//
// VPNs are the exception: `Quickshell.Networking` models wifi and wired devices
// only - a WireGuard connection has no DeviceType and never appears in
// `Networking.devices` - so those profiles are listed and toggled with nmcli.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import qs

Singleton {
    id: root

    readonly property var devices: Networking.devices.values

    readonly property WifiDevice wifi: {
        for (const dev of root.devices)
            if (dev.type === DeviceType.Wifi)
                return dev;
        return null;
    }

    // NM also hands out wired devices nothing can be done with (vboxnet0,
    // tethering bridges): unmanaged ones are not ours to connect.
    readonly property var wiredDevices: root.devices.filter(dev => dev.type === DeviceType.Wired && dev.nmManaged)

    readonly property WiredDevice wired: {
        for (const dev of root.wiredDevices)
            if (dev.connected)
                return dev;
        return null;
    }

    readonly property bool wifiEnabled: Networking.wifiEnabled
    readonly property bool wifiBlocked: !Networking.wifiHardwareEnabled

    // Connected first, then strongest. The pill and the panel read the same list.
    readonly property var networks: {
        if (root.wifi === null)
            return [];
        return root.wifi.networks.values.slice().sort((a, b) => {
            if (a.connected !== b.connected)
                return a.connected ? -1 : 1;
            return b.signalStrength - a.signalStrength;
        });
    }

    readonly property WifiNetwork activeWifi: {
        for (const net of root.networks)
            if (net.connected)
                return net;
        return null;
    }

    readonly property WifiNetwork pendingWifi: {
        for (const net of root.networks)
            if (net.state === ConnectionState.Connecting)
                return net;
        return null;
    }

    // A network that is up but gated: the connectivity check landed on a portal.
    readonly property bool portal: Networking.connectivity === NetworkConnectivity.Portal
    readonly property bool online: Networking.connectivity === NetworkConnectivity.Full

    function strengthGlyph(strength: real): string {
        if (strength >= 0.75)
            return Config.glyph.wifi4;
        if (strength >= 0.5)
            return Config.glyph.wifi3;
        if (strength >= 0.25)
            return Config.glyph.wifi2;
        return Config.glyph.wifi1;
    }

    function secured(net: WifiNetwork): bool {
        return net.security !== WifiSecurityType.Open && net.security !== WifiSecurityType.Owe;
    }

    // Turning a device off means telling NM to leave it alone: `disconnect()`
    // on its own only starts the autoconnect race, which is how wifi came back
    // two seconds after being switched off.
    function setWiredEnabled(dev: NetworkDevice, enabled: bool): void {
        dev.autoconnect = enabled;
        if (enabled) {
            if (dev.network !== null)
                dev.network.connect();
        } else {
            dev.disconnect();
        }
    }

    readonly property string linkGlyph: {
        if (root.wired !== null)
            return Config.glyph.ethernet;
        if (!root.wifiEnabled)
            return Config.glyph.wifiOff;
        if (root.activeWifi !== null)
            return root.strengthGlyph(root.activeWifi.signalStrength);
        return Config.glyph.wifiNone;
    }

    readonly property string glyph: root.vpnActive ? `${Config.glyph.vpn} ${root.linkGlyph}` : root.linkGlyph

    // Pink for the link, so it reads apart from the bluetooth pill beside it;
    // the VPN glyph in front of it is what says a tunnel is up.
    readonly property color color: {
        if (root.pendingWifi !== null)
            return Theme.yellow;
        if (root.wired === null && root.activeWifi === null)
            return Theme.grey;
        return root.portal ? Theme.orange : Theme.purple;
    }

    readonly property string tooltip: {
        const vpn = root.activeVpns.length > 0 ? ` - ${root.activeVpns.map(v => v.name).join(", ")}` : "";
        const suffix = root.portal ? " - login required" : (root.online ? "" : " - no internet");
        if (root.wired !== null) {
            const speed = root.wired.linkSpeed > 0 ? ` - ${root.wired.linkSpeed} Mb/s` : "";
            return `${root.wired.name} - ${root.wired.address}${speed}${vpn}${suffix}`;
        }
        if (root.wifiBlocked)
            return "Wi-Fi blocked by hardware switch";
        if (!root.wifiEnabled)
            return "Wi-Fi off";
        if (root.pendingWifi !== null)
            return `Connecting to ${root.pendingWifi.name}`;
        if (root.activeWifi === null)
            return "Wi-Fi on, not connected";
        return `${root.activeWifi.name} - ${Math.round(root.activeWifi.signalStrength * 100)}% - ${root.wifi.address}${vpn}${suffix}`;
    }

    // The radio wakes for every sweep, so the scanner runs only while the panel
    // is open. Without it the device lists the connected network alone.
    property bool scanning: false

    Binding {
        target: root.wifi
        property: "scannerEnabled"
        value: root.scanning
        when: root.wifi !== null
    }

    // `{ name, uuid, active }` per WireGuard or VPN profile.
    property var vpns: []
    readonly property var activeVpns: root.vpns.filter(vpn => vpn.active)
    readonly property bool vpnActive: root.activeVpns.length > 0
    property string vpnError: ""

    // nmcli --terse separates fields with ':' and escapes a literal one as '\:'.
    // Written out because a lookbehind regex does not split at all in QML's JS
    // engine - it silently returns the whole line as one field.
    function terseFields(line: string): var {
        const fields = [];
        let field = "";
        for (let i = 0; i < line.length; i++) {
            if (line[i] === "\\" && i + 1 < line.length)
                field += line[++i];
            else if (line[i] === ":") {
                fields.push(field);
                field = "";
            } else
                field += line[i];
        }
        fields.push(field);
        return fields;
    }

    function toggleVpn(vpn): void {
        root.vpnError = "";
        vpnAction.command = [Config.nmcli, "connection", vpn.active ? "down" : "up", "uuid", vpn.uuid];
        vpnAction.running = true;
    }

    // Saved wifi profiles by SSID: `{ uuid, autoconnect }`. NM's per-profile
    // autoconnect is not on `Network`, and it is the switch KDE puts on every
    // saved network.
    property var profiles: ({})

    function setAutoconnect(uuid: string, enabled: bool): void {
        root.vpnError = "";
        vpnAction.command = [Config.nmcli, "connection", "modify", "uuid", uuid, "connection.autoconnect", enabled ? "yes" : "no"];
        vpnAction.running = true;
    }

    Process {
        id: connectionList

        command: [Config.nmcli, "--terse", "--fields", "NAME,UUID,TYPE,ACTIVE,AUTOCONNECT", "connection", "show"]
        running: true

        stdout: StdioCollector {
            onStreamFinished: {
                const found = [];
                const saved = {};
                for (const line of text.trim().split("\n")) {
                    const cols = root.terseFields(line);
                    if (cols.length < 5)
                        continue;
                    const entry = {
                        name: cols[0],
                        uuid: cols[1],
                        active: cols[3] === "yes",
                        autoconnect: cols[4] === "yes"
                    };
                    if (cols[2] === "wireguard" || cols[2] === "vpn")
                        found.push(entry);
                    else if (cols[2] === "802-11-wireless")
                        saved[entry.name] = entry;
                }
                root.vpns = found;
                root.profiles = saved;
            }
        }
    }

    // `NetworkDevice.address` is the hardware address, so the IPs come from
    // nmcli too: device name -> `{ v4, v6 }`, first address of each family.
    property var addresses: ({})
    // The addresses flattened, so an nmcli refresh that reports the same ones
    // - which is most of them - is not mistaken for the route changing.
    property string addressSignature: ""

    function addressOf(name: string): var {
        return root.addresses[name] ?? {
            v4: "",
            v6: ""
        };
    }

    Process {
        id: addressList

        command: [Config.nmcli, "--terse", "--fields", "GENERAL.DEVICE,IP4.ADDRESS,IP6.ADDRESS", "device", "show"]
        running: true

        stdout: StdioCollector {
            onStreamFinished: {
                const map = {};
                let device = "";
                for (const line of text.split("\n")) {
                    const cols = root.terseFields(line);
                    // `nmcli --terse` leaves the colons of an IPv6 address
                    // unescaped, so the value is everything after the field
                    // name, not the second field.
                    const value = cols.slice(1).join(":").split("/")[0];
                    if (cols[0] === "GENERAL.DEVICE") {
                        device = value;
                        map[device] = {
                            v4: "",
                            v6: ""
                        };
                    } else if (device === "" || cols.length < 2) {
                        continue;
                    } else if (cols[0].startsWith("IP4.ADDRESS") && map[device].v4 === "") {
                        map[device].v4 = value;
                    } else if (cols[0].startsWith("IP6.ADDRESS") && map[device].v6 === "" && !value.startsWith("fe80")) {
                        // Link-local is on every interface and says nothing.
                        map[device].v6 = value;
                    }
                }
                const signature = Object.keys(map).sort().map(name => `${name}=${map[name].v4}/${map[name].v6}`).join(" ");
                const changed = signature !== root.addressSignature;
                root.addressSignature = signature;
                root.addresses = map;
                // A new address means a new way out, so the public one is
                // worth asking again - but only if it was ever asked.
                if (changed && (root.publicV4 !== "" || root.publicPending))
                    publicSettle.restart();
            }
        }
    }

    // Best effort, and the only thing that can answer it: with a full-tunnel
    // VPN up, the address the world sees is the one at the other end.
    property string publicV4: ""
    property string publicV6: ""
    property bool publicPending: false

    function refreshPublicIp(): void {
        // Cleared first: the previous answer is wrong the moment the route
        // changes, and a tunnel that swallows the request would otherwise
        // leave the old address on screen looking current.
        root.publicV4 = "";
        root.publicV6 = "";
        root.publicPending = true;
        let outstanding = 2;
        for (const [host, family] of [["https://api.ipify.org", "v4"], ["https://api6.ipify.org", "v6"]]) {
            const req = new XMLHttpRequest();
            const settle = value => {
                if (family === "v4")
                    root.publicV4 = value;
                else
                    root.publicV6 = value;
                if (--outstanding === 0)
                    root.publicPending = false;
            };
            req.onreadystatechange = () => {
                if (req.readyState === XMLHttpRequest.DONE)
                    settle(req.status === 200 ? req.responseText.trim() : "");
            };
            // A route into a tunnel that drops traffic never answers and never
            // errors; without this the lookup hangs for the TCP timeout.
            req.timeout = 5000;
            req.ontimeout = () => settle("");
            req.open("GET", host);
            req.send();
        }
    }

    // A VPN going up or down is the other way the route out changes; the
    // address tap handles the rest.
    onVpnActiveChanged: publicSettle.restart()

    Timer {
        id: publicSettle

        interval: 1500
        onTriggered: root.refreshPublicIp()
    }

    Process {
        id: vpnAction

        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "")
                root.vpnError = text.trim().split("\n")[0]
        }

        onExited: root.refresh()
    }

    function refresh(): void {
        connectionList.running = true;
        addressList.running = true;
    }

    // One held process instead of a poll: nmcli only speaks when NM's state
    // changes, and every line means the lists are worth re-reading.
    Process {
        id: monitor

        command: [Config.nmcli, "monitor"]
        running: true

        stdout: SplitParser {
            onRead: settle.restart()
        }
    }

    Timer {
        id: settle

        interval: 300
        onTriggered: root.refresh()
    }

    // Throughput per device, the one thing KDE's applet shows that nothing
    // here does. Sampled from one procfs read while the panel is open, so an
    // unopened panel costs nothing.
    property var rates: ({})
    property var previousBytes: null

    function rateOf(name: string): var {
        return root.rates[name] ?? {
            rx: 0,
            tx: 0
        };
    }

    function formatRate(bytes: real): string {
        if (bytes >= 1048576)
            return `${(bytes / 1048576).toFixed(1)} MB/s`;
        if (bytes >= 1024)
            return `${(bytes / 1024).toFixed(0)} kB/s`;
        return `${Math.round(bytes)} B/s`;
    }

    function sampleRates(): void {
        const now = {};
        for (const line of netDev.text().split("\n")) {
            const parts = line.trim().split(/\s+/);
            if (parts.length < 10 || !parts[0].endsWith(":"))
                continue;
            now[parts[0].slice(0, -1)] = [Number(parts[1]), Number(parts[9])];
        }
        const elapsed = root.previousBytes === null ? 0 : (Date.now() - root.previousBytes.at) / 1000;
        if (elapsed > 0.2) {
            const out = {};
            for (const name in now) {
                const before = root.previousBytes.bytes[name];
                if (before === undefined)
                    continue;
                out[name] = {
                    rx: Math.max(0, (now[name][0] - before[0]) / elapsed),
                    tx: Math.max(0, (now[name][1] - before[1]) / elapsed)
                };
            }
            root.rates = out;
        }
        root.previousBytes = {
            at: Date.now(),
            bytes: now
        };
    }

    FileView {
        id: netDev

        path: "/proc/net/dev"
        onLoaded: root.sampleRates()
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.scanning
        onTriggered: netDev.reload()
    }

    onScanningChanged: if (!root.scanning) {
        root.previousBytes = null;
        root.rates = {};
    }
}

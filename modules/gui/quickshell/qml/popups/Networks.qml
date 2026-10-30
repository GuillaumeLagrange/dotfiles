// Wi-Fi, wired and VPN state, and the connect / disconnect / forget actions.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Networking
import qs
import qs.components
import qs.services

ClickPanel {
    id: root

    panelWidth: 320
    accent: Theme.purple

    // The network whose actions are showing, the one being asked a passphrase,
    // the one the arrow keys are on, and the last connect failure.
    property var selected: null
    property var pskFor: null
    property var cursor: null
    property string error: ""

    // The networks whose name the typed filter matches, best first.
    readonly property var matching: find.filter(Net.networks, net => net.name)

    function step(delta: int): void {
        const nets = root.matching;
        if (nets.length === 0)
            return;
        const i = nets.indexOf(root.cursor);
        const next = i < 0 ? (delta > 0 ? 0 : nets.length - 1) : Math.max(0, Math.min(nets.length - 1, i + delta));
        root.cursor = nets[next];
        networkList.positionViewAtIndex(next, ListView.Contain);
    }

    // What Enter does: the row's Connect, or its passphrase prompt.
    function activate(net: var): void {
        root.cursor = net;
        root.error = "";
        root.selected = net;
        if (net.connected)
            return;
        if (!net.known && Net.secured(net)) {
            root.pskFor = net;
            return;
        }
        root.pskFor = null;
        net.connect();
    }

    onShown: {
        Net.scanning = true;
        Net.refresh();
        Net.refreshPublicIp();
        networkList.forceActiveFocus();
    }

    onHidden: {
        Net.scanning = false;
        root.selected = null;
        root.pskFor = null;
        root.cursor = null;
        find.query = "";
        root.error = "";
    }

    component Btn: Rectangle {
        id: btn

        required property string label
        // "accent", "danger" or "plain".
        property string kind: "plain"
        readonly property color tint: btn.kind === "accent" ? root.accent : (btn.kind === "danger" ? Theme.alpha(Theme.red, 0.22) : Theme.well)

        signal activated

        implicitWidth: caption.implicitWidth + 16
        implicitHeight: 22
        radius: Theme.rowRadius
        color: btn.tint
        opacity: hover.hovered ? 0.85 : 1

        Text {
            id: caption

            anchors.centerIn: parent
            text: btn.label
            color: btn.kind === "accent" ? Theme.ink : (btn.kind === "danger" ? Theme.soften(Theme.red) : Theme.fg)
            font.family: Theme.ui
            font.pixelSize: 11
        }

        HoverHandler {
            id: hover

            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            onSingleTapped: btn.activated()
        }
    }

    // One "IPv4  192.168.1.66" line; drawn only when there is a value.
    component Detail: RowLayout {
        id: detail

        required property string label
        required property string value

        Layout.fillWidth: true
        visible: detail.value !== ""
        spacing: 8

        Text {
            Layout.preferredWidth: 46
            text: detail.label
            color: Theme.faint
            font.family: Theme.ui
            font.pixelSize: 10
        }

        Text {
            Layout.fillWidth: true
            text: detail.value
            elide: Text.ElideRight
            color: Theme.dim
            font.family: Theme.ui
            font.pixelSize: 10
            font.features: { "tnum": 1 }
        }
    }

    // One network. Clicking it reveals its actions; a secured network that has
    // no saved profile - or one whose secrets NM cannot produce - reveals a
    // passphrase field with them.
    component NetRow: Rectangle {
        id: row

        required property var modelData
        // Null once NM drops the network, while the row is still on its way
        // out of the list.
        readonly property var net: row.modelData
        readonly property bool open: root.selected === row.net
        readonly property bool current: root.cursor !== null && root.cursor === row.net
        // A network the bar has to ask a passphrase for. Kept on the panel, which
        // is where a failed connect (below) reopens the prompt from.
        readonly property bool askPsk: root.pskFor === row.net
        readonly property bool connected: row.net?.connected ?? false
        readonly property bool known: row.net?.known ?? false
        readonly property bool secured: row.net !== null && Net.secured(row.net)
        readonly property var address: Net.addressOf(Net.wifi !== null ? Net.wifi.name : "")
        readonly property var rate: Net.rateOf(Net.wifi !== null ? Net.wifi.name : "")
        readonly property var profile: Net.profiles[row.net?.name ?? ""] ?? null

        // Never carry a typed passphrase over to another network.
        onNetChanged: psk.text = ""
        onAskPskChanged: if (row.askPsk)
            psk.forceActiveFocus()

        width: ListView.view.width
        implicitHeight: lines.implicitHeight + 8
        height: implicitHeight
        radius: Theme.rowRadius
        color: row.open || row.connected ? Theme.well : (hover.hovered || row.current ? Theme.hoverFill : "transparent")
        border.width: row.current ? 1 : 0
        border.color: Theme.alpha(root.accent, 0.6)

        ColumnLayout {
            id: lines

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 6
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 6

            RowLayout {
                Layout.fillWidth: true
                Layout.minimumHeight: 18
                spacing: 8

                // On the header only: a handler on the whole row would also
                // take the taps its own action buttons got, and collapse the
                // row out from under the click.
                TapHandler {
                    onSingleTapped: {
                        root.cursor = row.net;
                        if (row.open) {
                            root.selected = null;
                            return;
                        }
                        root.error = "";
                        root.selected = row.net;
                        root.pskFor = !row.net.known && Net.secured(row.net) ? row.net : null;
                    }
                }

                Text {
                    text: Net.strengthGlyph(row.net?.signalStrength ?? 0)
                    color: row.connected ? Theme.soften(root.accent) : Theme.dim
                    font.family: Theme.icon
                    font.pixelSize: 14
                }

                Text {
                    Layout.fillWidth: true
                    text: row.net?.name ?? ""
                    elide: Text.ElideRight
                    color: Theme.fg
                    font.family: Theme.ui
                    font.pixelSize: 12
                    font.weight: row.connected ? Font.DemiBold : Font.Normal
                }

                Text {
                    visible: row.secured
                    text: Config.glyph.lock
                    color: Theme.faint
                    font.family: Theme.icon
                    font.pixelSize: 11
                }

                Text {
                    text: row.net?.state === ConnectionState.Connecting ? "connecting" : (row.connected ? Net.formatRate(row.rate.rx) + " " + Config.glyph.down : (row.known ? "saved" : ""))
                    color: row.connected ? Theme.soften(root.accent) : Theme.faint
                    font.family: Theme.ui
                    font.pixelSize: 10
                    font.features: { "tnum": 1 }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: row.open
                spacing: 6

                Rectangle {
                    Layout.fillWidth: true
                    visible: row.askPsk
                    implicitHeight: 22
                    radius: Theme.rowRadius
                    color: Theme.well
                    border.width: 1
                    border.color: psk.activeFocus ? root.accent : Theme.border

                    TextInput {
                        id: psk

                        anchors.fill: parent
                        anchors.margins: 5
                        color: Theme.fg
                        echoMode: TextInput.Password
                        font.family: Theme.ui
                        font.pixelSize: 11
                        onAccepted: row.net.connectWithPsk(psk.text)
                        // A Backspace on an empty field is not the list filter's.
                        Keys.priority: Keys.AfterItem
                        Keys.onPressed: event => {
                            event.accepted = event.key === Qt.Key_Backspace;
                        }
                    }
                }

                Btn {
                    visible: !row.connected
                    label: row.askPsk ? "Join" : "Connect"
                    kind: "accent"
                    onActivated: {
                        root.error = "";
                        if (row.askPsk)
                            row.net.connectWithPsk(psk.text);
                        else
                            row.net.connect();
                    }
                }

                Btn {
                    visible: row.connected
                    label: "Disconnect"
                    onActivated: row.net.disconnect()
                }

                Btn {
                    visible: row.known
                    label: "Forget"
                    kind: "danger"
                    onActivated: {
                        row.net.forget();
                        root.selected = null;
                    }
                }
            }

            // What the connection actually gives you, which is the reason to
            // open a network panel at all.
            ColumnLayout {
                Layout.fillWidth: true
                visible: row.open && row.connected
                spacing: 2

                Detail {
                    label: "IPv4"
                    value: row.address.v4
                }
                Detail {
                    label: "IPv6"
                    value: row.address.v6
                }
                Detail {
                    label: "Traffic"
                    value: `${Config.glyph.down} ${Net.formatRate(row.rate.rx)}   ${Config.glyph.up} ${Net.formatRate(row.rate.tx)}`
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: row.open && row.profile !== null
                spacing: 8

                Text {
                    Layout.fillWidth: true
                    text: "Connect automatically"
                    color: Theme.dim
                    font.family: Theme.ui
                    font.pixelSize: 11
                }

                Switch {
                    accent: root.accent
                    on: row.profile !== null && row.profile.autoconnect
                    onToggled: Net.setAutoconnect(row.profile.uuid, !row.profile.autoconnect)
                }
            }
        }

        HoverHandler {
            id: hover

            cursorShape: Qt.PointingHandCursor
        }

        Connections {
            target: row.net

            // NM keeps some passphrases in a secret agent, which the bar is not;
            // asking for the network then fails here rather than at the prompt,
            // so the field is the answer to that too.
            function onConnectionFailed(reason): void {
                root.error = `${row.net.name}: ${ConnectionFailReason.toString(reason)}`;
                root.selected = row.net;
                root.pskFor = Net.secured(row.net) ? row.net : null;
            }
        }
    }

    // A wired device: the phone tethering over USB as much as an ethernet port.
    // Its switch is dead while no cable is in, since there is nothing to join.
    component WiredRow: ColumnLayout {
        id: wiredRow

        required property var modelData
        readonly property var dev: wiredRow.modelData
        readonly property var address: Net.addressOf(wiredRow.dev.name)
        readonly property var rate: Net.rateOf(wiredRow.dev.name)

        Layout.fillWidth: true
        Layout.leftMargin: 8
        Layout.rightMargin: 8
        spacing: 2

        RowLayout {
            Layout.fillWidth: true
            Layout.minimumHeight: 26
            spacing: 8

            Text {
                text: wiredRow.dev.hasLink ? Config.glyph.ethernet : Config.glyph.ethernetOff
                color: wiredRow.dev.connected ? Theme.soften(root.accent) : Theme.dim
                font.family: Theme.icon
                font.pixelSize: 14
            }

            Text {
                Layout.fillWidth: true
                text: wiredRow.dev.name
                elide: Text.ElideRight
                color: Theme.fg
                font.family: Theme.ui
                font.pixelSize: 12
            }

            Text {
                text: wiredRow.dev.connected ? `${Config.glyph.down} ${Net.formatRate(wiredRow.rate.rx)}` : (wiredRow.dev.hasLink ? "off" : "no cable")
                color: Theme.faint
                font.family: Theme.ui
                font.pixelSize: 10
                font.features: { "tnum": 1 }
            }

            Switch {
                accent: root.accent
                on: wiredRow.dev.connected
                live: wiredRow.dev.hasLink
                onToggled: Net.setWiredEnabled(wiredRow.dev, !wiredRow.dev.connected)
            }
        }

        Detail {
            Layout.leftMargin: 22
            label: "IPv4"
            value: wiredRow.dev.connected ? wiredRow.address.v4 : ""
        }

        Detail {
            Layout.leftMargin: 22
            label: "IPv6"
            value: wiredRow.dev.connected ? wiredRow.address.v6 : ""
        }
    }

    component VpnRow: RowLayout {
        id: vpnRow

        required property var modelData
        readonly property var vpn: vpnRow.modelData

        Layout.fillWidth: true
        Layout.leftMargin: 8
        Layout.rightMargin: 8
        Layout.minimumHeight: 26
        spacing: 8

        Text {
            text: Config.glyph.vpn
            color: vpnRow.vpn.active ? Theme.soften(root.accent) : Theme.dim
            font.family: Theme.icon
            font.pixelSize: 14
        }

        Text {
            Layout.fillWidth: true
            text: vpnRow.vpn.name
            elide: Text.ElideRight
            color: Theme.fg
            font.family: Theme.ui
            font.pixelSize: 12
        }

        Switch {
            accent: root.accent
            on: vpnRow.vpn.active
            onToggled: Net.toggleVpn(vpnRow.vpn)
        }
    }

    ColumnLayout {
        id: body

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 10

        PanelTitle {
            glyph: Net.linkGlyph
            text: "Wi-Fi"
            accent: root.accent

            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: Net.wifiBlocked
                text: "blocked"
                color: Theme.red
                font.family: Theme.ui
                font.pixelSize: 10
            }

            Switch {
                anchors.verticalCenter: parent.verticalCenter
                accent: root.accent
                on: Net.wifiEnabled
                live: !Net.wifiBlocked
                onToggled: Networking.wifiEnabled = !Networking.wifiEnabled
            }
        }

        SectionLabel {
            Layout.fillWidth: true
            visible: Net.wiredDevices.length > 0
            text: "Wired"
        }

        Repeater {
            model: Net.wiredDevices
            delegate: WiredRow {}
        }

        SectionLabel {
            Layout.fillWidth: true
            visible: Net.wiredDevices.length > 0
            text: "Networks"
        }

        Text {
            Layout.fillWidth: true
            visible: Net.networks.length === 0
            text: Net.wifiEnabled ? "Scanning..." : "Wi-Fi is off"
            color: Theme.dim
            font.family: Theme.ui
            font.pixelSize: 11
        }

        FindBar {
            id: find

            accent: root.accent
            empty: root.matching.length === 0
            // Typing puts the cursor on the best guess, so Enter takes it.
            onQueryChanged: {
                root.cursor = find.filter(Net.networks, net => net.name)[0] ?? null;
                networkList.positionViewAtBeginning();
            }
        }

        ListView {
            id: networkList

            Layout.fillWidth: true
            keyNavigationEnabled: false
            Keys.onUpPressed: root.step(-1)
            Keys.onDownPressed: root.step(1)
            Keys.onReturnPressed: if (root.cursor !== null)
                root.activate(root.cursor)
            Keys.onEnterPressed: if (root.cursor !== null)
                root.activate(root.cursor)
            Keys.onEscapePressed: event => {
                if (find.query !== "")
                    find.query = "";
                else
                    event.accepted = false;
            }
            Keys.onPressed: event => {
                event.accepted = find.type(event);
            }
            implicitHeight: Math.min(contentHeight, 260)
            clip: true
            spacing: 2
            // Diffed, not reassigned: every scan moves some signal strength,
            // and a plain array model rebuilds every row each time, taking a
            // half-typed passphrase and its focus with it.
            model: ScriptModel {
                values: root.matching
            }
            delegate: NetRow {}
        }

        SectionLabel {
            Layout.fillWidth: true
            visible: Net.vpns.length > 0
            text: "VPN"
        }

        Repeater {
            model: Net.vpns
            delegate: VpnRow {}
        }

        SectionLabel {
            Layout.fillWidth: true
            visible: Net.publicPending || Net.publicV4 !== "" || Net.publicV6 !== ""
            text: "Public IP"
        }

        Detail {
            Layout.leftMargin: 8
            label: "IPv4"
            value: Net.publicPending && Net.publicV4 === "" ? "checking..." : Net.publicV4
        }

        Detail {
            Layout.leftMargin: 8
            label: "IPv6"
            value: Net.publicV6
        }

        Text {
            Layout.fillWidth: true
            visible: root.error !== "" || Net.vpnError !== ""
            text: root.error !== "" ? root.error : Net.vpnError
            wrapMode: Text.Wrap
            color: Theme.red
            font.family: Theme.ui
            font.pixelSize: 10
        }
    }
}

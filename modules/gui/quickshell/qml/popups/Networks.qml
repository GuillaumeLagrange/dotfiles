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

    // The network whose actions are showing, the one being asked a passphrase,
    // and the last connect failure.
    property var selected: null
    property var pskFor: null
    property string error: ""

    onShown: {
        Net.scanning = true;
        Net.refresh();
        Net.refreshPublicIp();
    }

    onHidden: {
        Net.scanning = false;
        root.selected = null;
        root.pskFor = null;
        root.error = "";
    }

    component Btn: Rectangle {
        id: btn

        required property string label
        property color tint: Theme.alpha(Theme.fg, 0.1)

        signal activated

        implicitWidth: caption.implicitWidth + 16
        implicitHeight: 22
        radius: 4
        color: hover.hovered ? Qt.lighter(btn.tint, 1.4) : btn.tint

        Text {
            id: caption

            anchors.centerIn: parent
            text: btn.label
            color: Theme.fg
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
            color: Theme.alpha(Theme.fg, 0.4)
            font.family: Theme.ui
            font.pixelSize: 10
        }

        Text {
            Layout.fillWidth: true
            text: detail.value
            elide: Text.ElideRight
            color: Theme.alpha(Theme.fg, 0.75)
            font.family: Theme.mono
            font.pixelSize: 10
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

        width: ListView.view.width
        implicitHeight: lines.implicitHeight + 8
        height: implicitHeight
        radius: 6
        color: row.open ? Theme.alpha(Theme.fg, 0.1) : (hover.hovered ? Theme.alpha(Theme.fg, 0.06) : "transparent")

        ColumnLayout {
            id: lines

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 4
            spacing: 6

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                // On the header only: a handler on the whole row would also
                // take the taps its own action buttons got, and collapse the
                // row out from under the click.
                TapHandler {
                    onSingleTapped: {
                        if (row.open) {
                            root.selected = null;
                            return;
                        }
                        root.error = "";
                        root.selected = row.net;
                        root.pskFor = !row.net.known && Net.secured(row.net) ? row.net : null;
                        if (row.askPsk)
                            psk.forceActiveFocus();
                    }
                }

                Text {
                    text: Net.strengthGlyph(row.net?.signalStrength ?? 0)
                    color: row.connected ? Theme.blue : Theme.alpha(Theme.fg, 0.7)
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
                    font.bold: row.connected
                }

                Text {
                    visible: row.secured
                    text: Config.glyph.lock
                    color: Theme.alpha(Theme.fg, 0.4)
                    font.family: Theme.icon
                    font.pixelSize: 11
                }

                Text {
                    text: row.net?.state === ConnectionState.Connecting ? "connecting" : (row.connected ? Net.formatRate(row.rate.rx) + " " + Config.glyph.down : (row.known ? "saved" : ""))
                    color: row.connected ? Theme.blue : Theme.alpha(Theme.fg, 0.45)
                    font.family: Theme.ui
                    font.pixelSize: 10
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
                    radius: 4
                    color: Theme.alpha("#000000", 0.25)
                    border.width: 1
                    border.color: psk.activeFocus ? Theme.blue : Theme.border

                    TextInput {
                        id: psk

                        anchors.fill: parent
                        anchors.margins: 5
                        color: Theme.fg
                        echoMode: TextInput.Password
                        font.family: Theme.ui
                        font.pixelSize: 11
                        onAccepted: row.net.connectWithPsk(psk.text)
                    }
                }

                Btn {
                    visible: !row.connected
                    label: row.askPsk ? "Join" : "Connect"
                    tint: Theme.alpha(Theme.blue, 0.35)
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
                    tint: Theme.alpha(Theme.red, 0.3)
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
                    color: Theme.alpha(Theme.fg, 0.7)
                    font.family: Theme.ui
                    font.pixelSize: 11
                }

                Switch {
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
                if (row.askPsk)
                    psk.forceActiveFocus();
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
        spacing: 2

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                text: wiredRow.dev.hasLink ? Config.glyph.ethernet : Config.glyph.ethernetOff
                color: wiredRow.dev.connected ? Theme.blue : Theme.alpha(Theme.fg, 0.5)
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
                color: Theme.alpha(Theme.fg, 0.45)
                font.family: Theme.ui
                font.pixelSize: 10
            }

            Switch {
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
        spacing: 8

        Text {
            text: Config.glyph.vpn
            color: vpnRow.vpn.active ? Theme.purple : Theme.alpha(Theme.fg, 0.5)
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
            on: vpnRow.vpn.active
            onToggled: Net.toggleVpn(vpnRow.vpn)
        }
    }

    ColumnLayout {
        id: body

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 8

        Text {
            Layout.fillWidth: true
            visible: Net.wiredDevices.length > 0
            text: "Wired"
            color: Theme.grey
            font.family: Theme.ui
            font.pixelSize: 12
        }

        Repeater {
            model: Net.wiredDevices
            delegate: WiredRow {}
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Net.wiredDevices.length > 0 ? 4 : 0
            spacing: 8

            Text {
                Layout.fillWidth: true
                text: "Wi-Fi"
                color: Theme.grey
                font.family: Theme.ui
                font.pixelSize: 12
            }

            Text {
                visible: Net.wifiBlocked
                text: "blocked"
                color: Theme.red
                font.family: Theme.ui
                font.pixelSize: 10
            }

            Switch {
                on: Net.wifiEnabled
                live: !Net.wifiBlocked
                onToggled: Networking.wifiEnabled = !Networking.wifiEnabled
            }
        }

        Text {
            Layout.fillWidth: true
            visible: Net.networks.length === 0
            text: Net.wifiEnabled ? "Scanning..." : "Wi-Fi is off"
            color: Theme.alpha(Theme.fg, 0.45)
            font.family: Theme.ui
            font.pixelSize: 11
        }

        ListView {
            Layout.fillWidth: true
            implicitHeight: Math.min(contentHeight, 260)
            clip: true
            spacing: 2
            // Diffed, not reassigned: every scan moves some signal strength,
            // and a plain array model rebuilds every row each time, taking a
            // half-typed passphrase and its focus with it.
            model: ScriptModel {
                values: Net.networks
            }
            delegate: NetRow {}
        }

        Text {
            Layout.fillWidth: true
            Layout.topMargin: 4
            visible: Net.vpns.length > 0
            text: "VPN"
            color: Theme.grey
            font.family: Theme.ui
            font.pixelSize: 12
        }

        Repeater {
            model: Net.vpns
            delegate: VpnRow {}
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: 4
            visible: Net.publicPending || Net.publicV4 !== "" || Net.publicV6 !== ""
            implicitHeight: 1
            color: Theme.border
        }

        Detail {
            label: "Public"
            value: Net.publicPending && Net.publicV4 === "" ? "checking..." : Net.publicV4
        }

        Detail {
            label: ""
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

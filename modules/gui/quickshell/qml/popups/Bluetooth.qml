// Paired and nearby bluetooth devices, their batteries, and the connect /
// pair / forget actions.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Bluetooth
import qs
import qs.components
import qs.services

ClickPanel {
    id: root

    panelWidth: 320
    accent: Theme.blue

    // The device whose actions are showing.
    property var selected: null

    // Opening the panel only shows what is already known - paired devices are
    // there whether or not the radio is sweeping. Discovery is asked for.
    onHidden: {
        Bt.scanning = false;
        root.selected = null;
        Bt.pairError = "";
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

    // One device. Clicking it reveals what can be done with it, which depends
    // on whether it is paired: an unpaired one can only be paired.
    component DeviceRow: Rectangle {
        id: row

        required property var modelData
        // Null once BlueZ drops a scan hit, while the row is still on its way
        // out of the list.
        readonly property var dev: row.modelData
        readonly property bool open: root.selected === row.dev
        readonly property bool known: !!(row.dev?.paired || row.dev?.bonded)
        readonly property bool connected: row.dev?.connected ?? false
        readonly property bool pairing: Bt.pairingDevice !== null && Bt.pairingDevice === row.dev

        width: ListView.view.width
        implicitHeight: lines.implicitHeight + 8
        height: implicitHeight
        radius: Theme.rowRadius
        color: row.open || row.connected ? Theme.well : (hover.hovered ? Theme.hoverFill : "transparent")

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
                    onSingleTapped: root.selected = row.open ? null : row.dev
                }

                Text {
                    text: Bt.deviceGlyph(row.dev)
                    color: row.connected ? Theme.soften(root.accent) : Theme.dim
                    font.family: Theme.icon
                    font.pixelSize: 14
                }

                Text {
                    Layout.fillWidth: true
                    text: row.dev?.name || row.dev?.address || ""
                    elide: Text.ElideRight
                    color: Theme.fg
                    font.family: Theme.ui
                    font.pixelSize: 12
                    font.weight: row.connected ? Font.DemiBold : Font.Normal
                }

                Text {
                    text: Bt.batteryOf(row.dev)
                    color: Theme.dim
                    font.family: Theme.ui
                    font.pixelSize: 10
                    font.features: { "tnum": 1 }
                }

                Text {
                    text: row.pairing ? "pairing" : (row.dev?.state === BluetoothDeviceState.Connecting ? "connecting" : (row.connected ? "connected" : (row.known ? "paired" : "")))
                    color: row.connected ? Theme.soften(root.accent) : Theme.faint
                    font.family: Theme.ui
                    font.pixelSize: 10
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: row.open
                spacing: 6

                Btn {
                    visible: row.known && !row.connected
                    label: "Connect"
                    kind: "accent"
                    onActivated: row.dev.connect()
                }

                Btn {
                    visible: row.connected
                    label: "Disconnect"
                    onActivated: row.dev.disconnect()
                }

                Btn {
                    visible: !row.known && !row.pairing && Bt.pairingDevice === null
                    label: "Pair"
                    kind: "accent"
                    onActivated: Bt.pair(row.dev)
                }

                Btn {
                    visible: row.pairing
                    label: "Cancel"
                    onActivated: Bt.cancelPair()
                }

                Item {
                    Layout.fillWidth: true
                }

                Btn {
                    visible: row.known
                    label: "Forget"
                    kind: "danger"
                    onActivated: {
                        row.dev.forget();
                        root.selected = null;
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: row.open && row.known
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
                    on: row.dev?.trusted ?? false
                    onToggled: row.dev.trusted = !row.dev.trusted
                }
            }

            Flow {
                Layout.fillWidth: true
                visible: row.open && row.known
                spacing: 2

                Repeater {
                    model: Config.btDeviceGlyphs

                    Rectangle {
                        id: choice

                        required property string modelData
                        readonly property bool current: Bt.glyphKey(row.dev) === choice.modelData

                        width: 22
                        height: 22
                        radius: Theme.pillRadius
                        color: choice.current ? root.accent : (choiceHover.hovered ? Theme.hoverFill : "transparent")

                        Text {
                            anchors.centerIn: parent
                            text: Config.glyph[choice.modelData]
                            color: choice.current ? Theme.ink : Theme.dim
                            font.family: Theme.icon
                            font.pixelSize: 14
                        }

                        HoverHandler {
                            id: choiceHover

                            cursorShape: Qt.PointingHandCursor
                        }

                        TapHandler {
                            onSingleTapped: Bt.setGlyph(row.dev, choice.modelData)
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                visible: row.open
                text: row.dev?.address ?? ""
                color: Theme.faint
                font.family: Theme.ui
                font.pixelSize: 10
                font.features: { "tnum": 1 }
            }
        }

        HoverHandler {
            id: hover

            cursorShape: Qt.PointingHandCursor
        }
    }

    ColumnLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 10

        PanelTitle {
            glyph: Bt.glyph
            text: "Bluetooth"
            accent: root.accent

            Btn {
                anchors.verticalCenter: parent.verticalCenter
                visible: Bt.enabled
                label: Bt.discovering ? "Stop" : "Scan"
                kind: Bt.discovering ? "accent" : "plain"
                onActivated: Bt.scanning = !Bt.scanning
            }

            Switch {
                anchors.verticalCenter: parent.verticalCenter
                accent: root.accent
                on: Bt.enabled
                live: Bt.present
                onToggled: Bt.adapter.enabled = !Bt.adapter.enabled
            }
        }

        Text {
            Layout.fillWidth: true
            visible: !Bt.present || !Bt.enabled || Bt.devices.length === 0
            text: !Bt.present ? "No adapter" : (!Bt.enabled ? "Bluetooth is off" : (Bt.discovering ? "Looking for devices..." : "No devices - hit Scan"))
            color: Theme.dim
            font.family: Theme.ui
            font.pixelSize: 11
        }

        ListView {
            Layout.fillWidth: true
            implicitHeight: Math.min(contentHeight, 300)
            clip: true
            spacing: 2
            // Diffed, not reassigned: a scan changes the list several times a
            // second, and a plain array model rebuilds every row each time,
            // dropping a click on Pair between its press and its release.
            model: ScriptModel {
                values: Bt.devices
            }
            delegate: DeviceRow {}
        }

        Text {
            Layout.fillWidth: true
            visible: Bt.pairError !== ""
            text: Bt.pairError
            wrapMode: Text.Wrap
            color: Theme.red
            font.family: Theme.ui
            font.pixelSize: 10
        }
    }
}

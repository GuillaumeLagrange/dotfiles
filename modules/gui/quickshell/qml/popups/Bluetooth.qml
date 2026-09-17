// Paired and nearby bluetooth devices, their batteries, and the connect /
// pair / forget actions blueman-applet's menu used to carry.
import QtQuick
import QtQuick.Layouts
import Quickshell.Bluetooth
import qs
import qs.components
import qs.services

ClickPanel {
    id: root

    panelWidth: 320

    // The device whose actions are showing.
    property var selected: null

    // Opening the panel only shows what is already known - paired devices are
    // there whether or not the radio is sweeping. Discovery is asked for.
    onHidden: {
        Bt.scanning = false;
        root.selected = null;
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

    // One device. Clicking it reveals what can be done with it, which depends
    // on whether it is paired: an unpaired one can only be paired.
    component DeviceRow: Rectangle {
        id: row

        required property var modelData
        readonly property var dev: row.modelData
        readonly property bool open: root.selected === row.dev
        readonly property bool known: row.dev.paired || row.dev.bonded

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
                    onSingleTapped: root.selected = row.open ? null : row.dev
                }

                Text {
                    text: Bt.deviceGlyph(row.dev)
                    color: row.dev.connected ? Theme.blue : Theme.alpha(Theme.fg, 0.7)
                    font.family: Theme.icon
                    font.pixelSize: 14
                }

                Text {
                    Layout.fillWidth: true
                    text: row.dev.name || row.dev.address
                    elide: Text.ElideRight
                    color: Theme.fg
                    font.family: Theme.ui
                    font.pixelSize: 12
                    font.bold: row.dev.connected
                }

                Text {
                    text: Bt.batteryOf(row.dev)
                    color: Theme.alpha(Theme.fg, 0.6)
                    font.family: Theme.ui
                    font.pixelSize: 10
                }

                Text {
                    text: row.dev.pairing ? "pairing" : (row.dev.state === BluetoothDeviceState.Connecting ? "connecting" : (row.dev.connected ? "connected" : (row.known ? "paired" : "")))
                    color: row.dev.connected ? Theme.blue : Theme.alpha(Theme.fg, 0.45)
                    font.family: Theme.ui
                    font.pixelSize: 10
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: row.open
                spacing: 6

                Btn {
                    visible: row.known && !row.dev.connected
                    label: "Connect"
                    tint: Theme.alpha(Theme.blue, 0.35)
                    onActivated: row.dev.connect()
                }

                Btn {
                    visible: row.dev.connected
                    label: "Disconnect"
                    onActivated: row.dev.disconnect()
                }

                Btn {
                    visible: !row.known && !row.dev.pairing
                    label: "Pair"
                    tint: Theme.alpha(Theme.blue, 0.35)
                    onActivated: row.dev.pair()
                }

                Btn {
                    visible: row.dev.pairing
                    label: "Cancel"
                    onActivated: row.dev.cancelPair()
                }

                Item {
                    Layout.fillWidth: true
                }

                Btn {
                    visible: row.known
                    label: "Forget"
                    tint: Theme.alpha(Theme.red, 0.3)
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
                    color: Theme.alpha(Theme.fg, 0.7)
                    font.family: Theme.ui
                    font.pixelSize: 11
                }

                Switch {
                    on: row.dev.trusted
                    onToggled: row.dev.trusted = !row.dev.trusted
                }
            }

            Text {
                Layout.fillWidth: true
                visible: row.open
                text: row.dev.address
                color: Theme.alpha(Theme.fg, 0.4)
                font.family: Theme.mono
                font.pixelSize: 10
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
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                Layout.fillWidth: true
                text: "Bluetooth"
                color: Theme.grey
                font.family: Theme.ui
                font.pixelSize: 12
            }

            Btn {
                visible: Bt.enabled
                label: Bt.discovering ? "Stop" : "Scan"
                tint: Bt.discovering ? Theme.alpha(Theme.blue, 0.35) : Theme.alpha(Theme.fg, 0.1)
                onActivated: Bt.scanning = !Bt.scanning
            }

            Switch {
                on: Bt.enabled
                live: Bt.present
                onToggled: Bt.adapter.enabled = !Bt.adapter.enabled
            }
        }

        Text {
            Layout.fillWidth: true
            visible: !Bt.present || !Bt.enabled || Bt.devices.length === 0
            text: !Bt.present ? "No adapter" : (!Bt.enabled ? "Bluetooth is off" : (Bt.discovering ? "Looking for devices..." : "No devices - hit Scan"))
            color: Theme.alpha(Theme.fg, 0.45)
            font.family: Theme.ui
            font.pixelSize: 11
        }

        ListView {
            Layout.fillWidth: true
            implicitHeight: Math.min(contentHeight, 300)
            clip: true
            spacing: 2
            model: Bt.devices
            delegate: DeviceRow {}
        }
    }
}

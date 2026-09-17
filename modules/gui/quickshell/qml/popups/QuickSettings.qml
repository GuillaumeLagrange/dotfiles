// Quick-settings drawer: idle-inhibit and do-not-disturb toggles, the
// power-profile segmented selector, and a battery footer (hidden on desktops).
import QtQuick
import QtQuick.Layouts
import Quickshell.Services.UPower
import qs
import qs.components
import qs.services

PopupPanel {
    id: root

    minContentWidth: 300

    readonly property var battery: UPower.displayDevice
    readonly property bool hasBattery: !!battery && battery.isLaptopBattery && battery.isPresent
    readonly property int batteryPct: hasBattery ? Math.round(battery.percentage * 100) : 0
    readonly property bool batteryCharging: hasBattery && (battery.state === UPowerDeviceState.Charging || battery.state === UPowerDeviceState.FullyCharged)
    readonly property bool batteryCritical: hasBattery && !batteryCharging && batteryPct <= 15
    readonly property string batteryIcon: {
        if (!hasBattery)
            return "";
        if (batteryCharging)
            return Config.glyph.batCharging;
        if (batteryPct >= 67)
            return Config.glyph.batHigh;
        if (batteryPct >= 34)
            return Config.glyph.batMedium;
        return Config.glyph.batLow;
    }

    // Whole-row click target: icon tile, label + sub-line, track/knob switch.
    // `active` drives every accent (tile tint, icon color, switch fill, knob ink).
    component ToggleRow: Rectangle {
        id: row

        required property string icon
        required property string label
        required property string sub
        required property bool active

        signal activated

        Layout.fillWidth: true
        implicitHeight: 50
        radius: 8
        color: active ? (hover.hovered ? Theme.alpha(Theme.aqua, 0.22) : Theme.alpha(Theme.aqua, 0.14)) : (hover.hovered ? Theme.alpha(Theme.fg, 0.07) : Theme.alpha("#000000", 0.18))

        RowLayout {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 12

            Rectangle {
                Layout.preferredWidth: 32
                Layout.preferredHeight: 32
                radius: 8
                color: row.active ? Theme.alpha(Theme.aqua, 0.22) : Theme.alpha(Theme.fg, 0.08)

                Text {
                    anchors.centerIn: parent
                    text: row.icon
                    font.family: Theme.icon
                    font.pixelSize: 15
                    color: row.active ? Theme.aqua : Theme.alpha(Theme.fg, 0.55)
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Text {
                    // Without fillWidth a Text cannot be shrunk below its
                    // implicit width, so a long label pushed the switch out of
                    // line with the row above it.
                    Layout.fillWidth: true
                    text: row.label
                    elide: Text.ElideRight
                    color: Theme.fg
                    font.family: Theme.ui
                    font.pixelSize: 13
                }
                Text {
                    Layout.fillWidth: true
                    text: row.sub
                    elide: Text.ElideRight
                    color: Theme.alpha(Theme.fg, 0.45)
                    font.family: Theme.ui
                    font.pixelSize: 10
                }
            }

            Switch {
                on: row.active
                interactive: false
            }
        }

        HoverHandler {
            id: hover

            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            onSingleTapped: row.activated()
        }
    }

    // One segment of the power-profile selector. Equal width so the selected
    // fill doesn't resize the group as the selection moves between segments.
    component ProfSeg: Rectangle {
        id: seg

        required property string icon
        required property string label
        required property string profileName

        readonly property bool selected: Quick.profileName === profileName
        readonly property color tint: profileName === "performance" ? Theme.red : profileName === "power-saver" ? Theme.green : Theme.blue

        Layout.fillWidth: true
        implicitHeight: 44
        radius: 6
        color: selected ? tint : (hover.hovered ? Theme.alpha(Theme.fg, 0.08) : "transparent")

        ColumnLayout {
            anchors.centerIn: parent
            spacing: 2

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: seg.icon
                font.family: Theme.icon
                font.pixelSize: 15
                color: seg.selected ? Theme.ink : (hover.hovered ? Theme.fg : Theme.alpha(Theme.fg, 0.6))
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: seg.label
                font.family: Theme.ui
                font.pixelSize: 10
                font.bold: seg.selected
                color: seg.selected ? Theme.ink : (hover.hovered ? Theme.fg : Theme.alpha(Theme.fg, 0.6))
            }
        }

        HoverHandler {
            id: hover

            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            onSingleTapped: Quick.setProfile(seg.profileName)
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8

        Text {
            Layout.fillWidth: true
            text: "Quick Settings"
            color: Theme.grey
            font.family: Theme.ui
            font.pixelSize: 12
        }

        ToggleRow {
            icon: Config.glyph.idle
            label: "Idle inhibit"
            sub: Quick.idleInhibit ? "Screen stays awake" : "Screen may lock"
            active: Quick.idleInhibit
            onActivated: Quick.toggleIdle()
        }

        ToggleRow {
            icon: Config.glyph.dnd
            label: "Do Not Disturb"
            sub: Quick.dndOn ? "Notifications muted" : "Notifications shown"
            active: Quick.dndOn
            onActivated: Quick.toggleDnd()
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4
            spacing: 6

            Text {
                text: "Power profile"
                color: Theme.alpha(Theme.fg, 0.45)
                font.family: Theme.ui
                font.pixelSize: 10
                font.bold: true
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: profSegs.implicitHeight + 8
                radius: 8
                color: Theme.alpha("#000000", 0.22)

                RowLayout {
                    id: profSegs
                    anchors.fill: parent
                    anchors.margins: 4
                    spacing: 4

                    ProfSeg {
                        icon: Config.glyph.saver
                        label: "Saver"
                        profileName: "power-saver"
                    }
                    ProfSeg {
                        icon: Config.glyph.balanced
                        label: "Balanced"
                        profileName: "balanced"
                    }
                    ProfSeg {
                        icon: Config.glyph.performance
                        label: "Perf"
                        profileName: "performance"
                    }
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: 10
            visible: root.hasBattery
            spacing: 8

            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Theme.border
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Text {
                    text: root.batteryIcon
                    font.family: Theme.icon
                    font.pixelSize: 15
                    color: root.batteryCharging ? Theme.green : (root.batteryCritical ? Theme.red : Theme.alpha(Theme.fg, 0.7))
                }
                Text {
                    Layout.fillWidth: true
                    text: root.batteryCharging ? "Charging" : "On battery"
                    color: Theme.alpha(Theme.fg, 0.7)
                    font.family: Theme.ui
                    font.pixelSize: 12
                }
                Text {
                    text: root.batteryPct + "%"
                    color: Theme.fg
                    font.family: Theme.ui
                    font.pixelSize: 12
                    font.bold: true
                }
            }
        }
    }
}

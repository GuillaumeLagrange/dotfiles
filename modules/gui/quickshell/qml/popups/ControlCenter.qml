// Control centre: what arrived, and the toggles that decide what arrives.
//
// One panel rather than a notification centre beside a quick-settings drawer -
// do-not-disturb belonged to both, and they were two surfaces hanging off two
// pills for one thing.
//
// Notifications sit above the toggles because the panel grows upwards from the
// pill: the controls then stay where they were, whatever the list is doing.
//
// The rows are snapshots, not live notifications, so a row acts through the
// notification behind it: the service holds an actionable one open past its
// popup, and the row carries its buttons for as long as that lasts.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Services.UPower
import qs
import qs.components
import qs.services

ClickPanel {
    id: root

    panelWidth: 420

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

    onShown: Notifs.markAllRead()

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

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                Layout.fillWidth: true
                text: "Notifications"
                color: Theme.grey
                font.family: Theme.ui
                font.pixelSize: 12
            }

            Rectangle {
                visible: Notifs.history.length > 0
                implicitWidth: clearLabel.implicitWidth + 16
                implicitHeight: 22
                radius: 6
                color: clearHover.hovered ? Theme.alpha(Theme.fg, 0.18) : Theme.alpha(Theme.fg, 0.09)

                Text {
                    id: clearLabel

                    anchors.centerIn: parent
                    text: "Clear all"
                    color: Theme.fg
                    font.family: Theme.ui
                    font.pixelSize: 11
                }

                HoverHandler {
                    id: clearHover

                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    onSingleTapped: Notifs.clearAll()
                }
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.topMargin: 6
            Layout.bottomMargin: 6
            visible: Notifs.history.length === 0
            text: Notifs.dnd ? "Nothing to catch up on - notifications are muted" : "Nothing to catch up on"
            horizontalAlignment: Text.AlignHCenter
            color: Theme.alpha(Theme.fg, 0.35)
            font.family: Theme.ui
            font.pixelSize: 12
        }

        ListView {
            id: list

            Layout.fillWidth: true
            // A ListView has no implicit height, and the panel's window covers
            // the output, so the rest of the panel is measured out of the
            // screen rather than guessed: a full history otherwise pushed the
            // toggles off the top edge.
            Layout.preferredHeight: Math.min(list.contentHeight, 480, Math.max(120, root.height - 420))
            visible: Notifs.history.length > 0
            clip: true
            spacing: 6
            model: Notifs.history

            // Shown only while the list is capped - which is the only time it
            // scrolls - and the rows give up its width, so the handle never
            // sits on a card's border.
            ScrollBar.vertical: ScrollBar {
                id: vbar

                policy: list.contentHeight > list.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                implicitWidth: 8
                padding: 2
                background: null

                contentItem: Rectangle {
                    radius: width / 2
                    color: Theme.alpha(Theme.fg, vbar.pressed ? 0.5 : vbar.hovered ? 0.35 : 0.2)
                }
            }

            delegate: NotifCard {
                id: card

                required property var modelData

                width: list.width - (vbar.visible ? vbar.implicitWidth + 2 : 0)
                appName: card.modelData.appName
                summary: card.modelData.summary
                body: card.modelData.body
                iconSource: Notifs.iconFor(card.modelData.image, card.modelData.appIcon)
                critical: card.modelData.critical
                time: Notifs.ago(card.modelData.time)
                actions: Notifs.actionsFor(card.modelData.notifId)

                onActivated: Notifs.activateEntry(card.modelData)
                onDismissed: Notifs.forget(card.modelData.key)
                onActionInvoked: action => Notifs.invokeEntryAction(card.modelData, action)
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: 6
            height: 1
            color: Theme.border
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
            sub: Notifs.dnd ? "Notifications muted" : "Notifications shown"
            active: Notifs.dnd
            onActivated: Notifs.toggleDnd()
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

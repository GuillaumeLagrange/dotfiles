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
    accent: Quick.gearColor

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

    // Whole-row click target: icon chip, label + sub-line, switch.
    // Given `modes`, a segmented selector replaces the switch and the row itself
    // stops being a click target; `active` then shows the effect, not the mode.
    component ToggleRow: Rectangle {
        id: row

        required property string icon
        required property string label
        required property string sub
        required property bool active
        property var modes: []
        property string mode: ""

        signal activated
        signal picked(string mode)

        Layout.fillWidth: true
        implicitHeight: 46
        radius: Theme.rowRadius
        color: hover.hovered ? Theme.hoverFill : "transparent"

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 10
            spacing: 10

            Rectangle {
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                radius: Theme.rowRadius
                color: row.active ? root.accent : Theme.alpha(Theme.fg, 0.08)

                Text {
                    anchors.centerIn: parent
                    text: row.icon
                    font.family: Theme.icon
                    font.pixelSize: 14
                    color: row.active ? Theme.ink : Theme.dim
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1

                Text {
                    // Without fillWidth a long label pushes the switch out of line.
                    Layout.fillWidth: true
                    text: row.label
                    elide: Text.ElideRight
                    color: Theme.fg
                    font.family: Theme.ui
                    font.pixelSize: 12
                    font.weight: Font.Medium
                }
                Text {
                    Layout.fillWidth: true
                    text: row.sub
                    elide: Text.ElideRight
                    color: Theme.dim
                    font.family: Theme.ui
                    font.pixelSize: 10
                }
            }

            Switch {
                visible: row.modes.length === 0
                on: row.active
                interactive: false
                accent: root.accent
            }

            Rectangle {
                visible: row.modes.length > 0
                implicitWidth: modeSegs.implicitWidth + 4
                implicitHeight: modeSegs.implicitHeight + 4
                radius: Theme.rowRadius
                color: Theme.well

                RowLayout {
                    id: modeSegs

                    anchors.centerIn: parent
                    spacing: 2

                    Repeater {
                        model: row.modes

                        Rectangle {
                            id: modeSeg

                            required property var modelData
                            readonly property bool selected: row.mode === modelData.value

                            implicitWidth: 40
                            implicitHeight: 22
                            radius: Theme.rowRadius - 1
                            color: selected ? root.accent : (segHover.hovered ? Theme.hoverFill : "transparent")

                            Text {
                                anchors.centerIn: parent
                                text: modeSeg.modelData.label
                                font.family: Theme.ui
                                font.pixelSize: 10
                                font.weight: modeSeg.selected ? Font.DemiBold : Font.Normal
                                color: modeSeg.selected ? Theme.ink : (segHover.hovered ? Theme.fg : Theme.dim)
                            }

                            HoverHandler {
                                id: segHover

                                cursorShape: Qt.PointingHandCursor
                            }

                            TapHandler {
                                onSingleTapped: row.picked(modeSeg.modelData.value)
                            }
                        }
                    }
                }
            }
        }

        HoverHandler {
            id: hover

            enabled: row.modes.length === 0
            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            enabled: row.modes.length === 0
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

        Layout.fillWidth: true
        implicitHeight: 30
        radius: Theme.rowRadius - 1
        color: selected ? root.accent : (hover.hovered ? Theme.hoverFill : "transparent")

        RowLayout {
            anchors.centerIn: parent
            spacing: 6

            Text {
                text: seg.icon
                font.family: Theme.icon
                font.pixelSize: 13
                color: seg.selected ? Theme.ink : (hover.hovered ? Theme.fg : Theme.dim)
            }
            Text {
                text: seg.label
                font.family: Theme.ui
                font.pixelSize: 11
                font.weight: seg.selected ? Font.DemiBold : Font.Normal
                color: seg.selected ? Theme.ink : (hover.hovered ? Theme.fg : Theme.dim)
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
        spacing: 10

        PanelTitle {
            glyph: Config.glyph.controls
            text: "Control center"
            accent: root.accent
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                SectionLabel {
                    Layout.fillWidth: true
                    text: "Notifications"
                }

                Rectangle {
                    visible: Notifs.history.length > 0
                    implicitWidth: clearLabel.implicitWidth + 14
                    implicitHeight: 20
                    radius: Theme.pillRadius
                    color: clearHover.hovered ? Theme.alpha(Theme.fg, 0.14) : Theme.alpha(Theme.fg, 0.07)

                    Text {
                        id: clearLabel

                        anchors.centerIn: parent
                        text: "Clear"
                        color: Theme.fg
                        font.family: Theme.ui
                        font.pixelSize: 10
                        font.weight: Font.Medium
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

            Rectangle {
                Layout.fillWidth: true
                visible: Notifs.history.length === 0
                implicitHeight: 44
                radius: Theme.rowRadius
                color: Theme.well

                Text {
                    anchors.centerIn: parent
                    text: Notifs.dnd ? "Nothing to catch up on - notifications are muted" : "Nothing to catch up on"
                    color: Theme.faint
                    font.family: Theme.ui
                    font.pixelSize: 11
                }
            }

            ListView {
                id: list

                Layout.fillWidth: true
                // A ListView has no implicit height, and the panel's window covers
                // the output, so the rest of the panel is measured out of the
                // screen rather than guessed.
                Layout.preferredHeight: Math.min(list.contentHeight, 480, Math.max(120, root.height - 420))
                visible: Notifs.history.length > 0
                clip: true
                spacing: 6
                model: Notifs.history

                // Shown only while the list is capped, and the rows give up its width.
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
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6

            SectionLabel {
                text: "Quick toggles"
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: toggles.implicitHeight + 8
                radius: Theme.rowRadius
                color: Theme.well

                ColumnLayout {
                    id: toggles

                    anchors.fill: parent
                    anchors.margins: 4
                    spacing: 2

                    ToggleRow {
                        icon: Config.glyph.dnd
                        label: "Do Not Disturb"
                        sub: Notifs.dnd ? "Notifications muted" : "Notifications shown"
                        active: Notifs.dnd
                        onActivated: Notifs.toggleDnd()
                    }

                    ToggleRow {
                        icon: Config.glyph.idle
                        label: "Idle inhibit"
                        sub: Quick.idleInhibit ? "Screen stays awake" : "Screen may lock"
                        active: Quick.idleInhibit
                        onActivated: Quick.toggleIdle()
                    }

                    ToggleRow {
                        visible: Quick.caffeineAvailable
                        icon: Config.glyph.caffeine
                        label: "Caffeine"
                        sub: Quick.caffeine ? "Lid close does not suspend" : Quick.caffeineMode === "auto" ? "Triggered automatically" : "Lid close suspends"
                        active: Quick.caffeine
                        modes: [
                            {
                                value: "off",
                                label: "Off"
                            },
                            {
                                value: "auto",
                                label: "Auto"
                            },
                            {
                                value: "on",
                                label: "On"
                            }
                        ]
                        mode: Quick.caffeineMode
                        onPicked: mode => Quick.setCaffeineMode(mode)
                    }
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6

            SectionLabel {
                text: "Power profile"
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: profSegs.implicitHeight + 4
                radius: Theme.rowRadius
                color: Theme.well

                RowLayout {
                    id: profSegs
                    anchors.fill: parent
                    anchors.margins: 2
                    spacing: 2

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
                        label: "Performance"
                        profileName: "performance"
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 8
            Layout.rightMargin: 10
            visible: root.hasBattery
            spacing: 10

            Text {
                text: root.batteryIcon
                font.family: Theme.icon
                font.pixelSize: 14
                color: root.batteryCritical ? Theme.red : (root.batteryCharging ? Theme.soften(root.accent) : Theme.dim)
            }
            Text {
                Layout.fillWidth: true
                text: root.batteryCharging ? "Charging" : "On battery"
                color: Theme.dim
                font.family: Theme.ui
                font.pixelSize: 11
            }
            Text {
                text: root.batteryPct + "%"
                color: root.batteryCritical ? Theme.red : Theme.fg
                font.family: Theme.ui
                font.pixelSize: 12
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
            }
        }
    }
}

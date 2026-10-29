// Disk, CPU, RAM and battery as one block: a level bar per segment, the exact
// figures in each segment's tooltip. Battery shows its number.
import QtQuick
import Quickshell
import Quickshell.Services.UPower
import qs
import qs.components
import qs.services

Rectangle {
    id: root

    readonly property var battery: UPower.displayDevice
    readonly property int batteryPct: Math.round(battery.percentage * 100)
    readonly property bool charging: battery.state === UPowerDeviceState.Charging || battery.state === UPowerDeviceState.FullyCharged
    readonly property int diskPct: {
        const m = /\((\d+)%\)/.exec(Sys.disk.tooltip);
        return m ? parseInt(m[1]) : 0;
    }
    readonly property int memPct: {
        const m = /(\d+)%/.exec(Sys.memswap.text);
        return m ? parseInt(m[1]) : 0;
    }
    readonly property string batteryTip: {
        const eta = root.charging ? root._eta(root.battery.timeToFull, "until full") : root._eta(root.battery.timeToEmpty, "remaining");
        const base = `Battery ${root.batteryPct}% \u2014 ${UPowerDeviceState.toString(root.battery.state)}`;
        return eta ? `${base}\n${eta}` : base;
    }

    function _eta(seconds: real, label: string): string {
        if (!(seconds > 0))
            return "";
        const mins = Math.floor(seconds / 60);
        return `${Math.floor(mins / 60)}h${String(mins % 60).padStart(2, "0")}m ${label}`;
    }

    readonly property var segments: [
        { glyph: Config.glyph.disk, color: Theme.purple, level: root.diskPct, tip: Sys.disk.tooltip },
        { glyph: Config.glyph.cpu, color: Theme.yellow, level: parseInt(Sys.cpu.usage), tip: Sys.cpu.tooltip },
        { glyph: Config.glyph.ram, color: Theme.blue, level: root.memPct, tip: Sys.memswap.tooltip },
        { glyph: root.charging ? Config.glyph.batCharging : root.batteryPct >= 67 ? Config.glyph.batHigh : root.batteryPct >= 34 ? Config.glyph.batMedium : Config.glyph.batLow, color: root.charging ? Theme.green : root.batteryPct <= 15 ? Theme.red : Theme.fg, level: root.batteryPct, text: `${root.batteryPct}%`, tip: root.batteryTip }
    ].filter(s => s.text === undefined || root.battery.isLaptopBattery)

    implicitWidth: row.implicitWidth
    implicitHeight: Theme.pillHeight
    radius: Theme.pillRadius
    color: "transparent"

    Row {
        id: row

        Repeater {
            // A count, not the array: every sample builds a new array, and an
            // array model would recreate the delegates and drop an open tooltip.
            model: root.segments.length

            delegate: Rectangle {
                id: seg

                required property int index
                readonly property var modelData: root.segments[seg.index] ?? ({})

                implicitWidth: content.implicitWidth + 12
                implicitHeight: Theme.pillHeight
                color: seg.modelData.color
                topLeftRadius: seg.index === 0 ? Theme.pillRadius : 0
                bottomLeftRadius: seg.index === 0 ? Theme.pillRadius : 0
                topRightRadius: seg.index === root.segments.length - 1 ? Theme.pillRadius : 0
                bottomRightRadius: seg.index === root.segments.length - 1 ? Theme.pillRadius : 0

                HoverHandler {
                    id: segHover
                }

                Timer {
                    id: dwell
                    interval: 400
                    onTriggered: tip.active = seg.modelData.tip !== ""
                }

                Connections {
                    target: segHover

                    function onHoveredChanged(): void {
                        if (segHover.hovered) {
                            dwell.restart();
                        } else {
                            dwell.stop();
                            tip.active = false;
                        }
                    }
                }

                LazyLoader {
                    id: tip

                    component: Component {
                        Tip {
                            target: seg
                            text: seg.modelData.tip
                        }
                    }
                }

                Row {
                    id: content

                    anchors.centerIn: parent
                    spacing: 4

                    Glyph {
                        anchors.verticalCenter: parent.verticalCenter
                        text: seg.modelData.glyph
                        color: Theme.ink
                        size: Theme.fontSize
                    }

                    // Level meter: the segment's value without the digits.
                    Rectangle {
                        visible: seg.modelData.text === undefined
                        anchors.verticalCenter: parent.verticalCenter
                        width: 4
                        height: 14
                        radius: 2
                        color: Theme.alpha(Theme.ink, 0.22)

                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width
                            height: Math.max(2, parent.height * Math.min(100, seg.modelData.level) / 100)
                            radius: 2
                            color: Theme.ink
                        }
                    }

                    Text {
                        visible: seg.modelData.text !== undefined
                        anchors.verticalCenter: parent.verticalCenter
                        text: seg.modelData.text
                        color: Theme.ink
                        font.family: Theme.mono
                        font.pixelSize: Theme.fontSize
                    }
                }
            }
        }
    }
}

// One bar window, bottom-anchored, 30px of exclusive zone for a 28px bar: the
// top 2px stay transparent so tiled windows stop short of the pills instead of
// butting against them.
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs

PanelWindow {
    id: bar

    required property var modelData
    readonly property string monitor: modelData.name

    screen: modelData
    color: "transparent"
    implicitHeight: Theme.windowHeight

    anchors {
        bottom: true
        left: true
        right: true
    }

    Rectangle {
        anchors.fill: parent
        anchors.topMargin: Theme.windowHeight - Theme.barHeight
        color: Theme.barBg

        RowLayout {
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.gap

            Workspaces {
                Layout.alignment: Qt.AlignVCenter
                monitor: bar.monitor
            }

            Strip {
                Layout.alignment: Qt.AlignVCenter
                monitor: bar.monitor
            }

            WindowTitle {
                Layout.alignment: Qt.AlignVCenter
                monitor: bar.monitor
            }
        }

        RowLayout {
            anchors.right: parent.right
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.gap

            RecordPill {
                Layout.alignment: Qt.AlignVCenter
            }

            MprisPill {
                Layout.alignment: Qt.AlignVCenter
            }

            Tray {
                Layout.alignment: Qt.AlignVCenter
            }

            ClaudePill {
                Layout.alignment: Qt.AlignVCenter
            }

            DiskPill {
                Layout.alignment: Qt.AlignVCenter
            }

            CpuPill {
                Layout.alignment: Qt.AlignVCenter
            }

            MemPill {
                Layout.alignment: Qt.AlignVCenter
            }

            BatteryPill {
                Layout.alignment: Qt.AlignVCenter
            }

            AudioPill {
                Layout.alignment: Qt.AlignVCenter
            }

            SettingsPill {
                Layout.alignment: Qt.AlignVCenter
            }

            ClockPill {
                Layout.alignment: Qt.AlignVCenter
            }
        }
    }
}

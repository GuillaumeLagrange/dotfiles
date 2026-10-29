// Two-month calendar with ISO week numbers, computed from JS Date.
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs
import qs.components

PopupPanel {
    id: root
    accent: Theme.aqua

    // Months from the current one; both panes move together off one offset.
    property int offset: 0

    // Refreshed on open too: the hourly timer is late after a suspend.
    property date now: new Date()

    readonly property var leftGrid: monthGrid(now, offset)
    readonly property var rightGrid: monthGrid(now, offset + 1)

    SystemClock {
        precision: SystemClock.Hours
        onDateChanged: root.now = new Date()
    }

    onOpenChanged: {
        if (root.open)
            root.now = new Date();
        else
            root.offset = 0;
    }

    function monthGrid(now: date, delta: int): var {
        const first = new Date(now.getFullYear(), now.getMonth() + delta, 1);
        // ISO weekday: Monday=0 .. Sunday=6.
        const dow = (first.getDay() + 6) % 7;
        const start = new Date(first.getFullYear(), first.getMonth(), first.getDate() - dow);

        const weeks = [];
        for (let w = 0; w < 6; w++) {
            const monday = new Date(start.getFullYear(), start.getMonth(), start.getDate() + w * 7);
            const days = [];
            for (let d = 0; d < 7; d++) {
                const cur = new Date(monday.getFullYear(), monday.getMonth(), monday.getDate() + d);
                days.push({
                    day: cur.getDate(),
                    other: cur.getMonth() !== first.getMonth(),
                    today: cur.toDateString() === now.toDateString(),
                    weekend: cur.getDay() === 0 || cur.getDay() === 6
                });
            }
            weeks.push({
                num: isoWeekNumber(monday),
                days: days
            });
        }

        return {
            title: Qt.formatDate(first, "MMMM"),
            year: first.getFullYear(),
            weeks: weeks
        };
    }

    function isoWeekNumber(monday: date): int {
        const thursday = new Date(monday.getFullYear(), monday.getMonth(), monday.getDate() + 3);
        const jan4 = new Date(thursday.getFullYear(), 0, 4);
        const jan4Dow = (jan4.getDay() + 6) % 7;
        const week1Monday = new Date(jan4.getFullYear(), 0, 4 - jan4Dow);
        const diffDays = Math.round((thursday - week1Monday) / 86400000);
        return 1 + Math.floor(diffDays / 7);
    }

    // One month's weekday header + 6-week grid; the title is drawn once in the
    // shared header row above, not per column.
    component MonthColumn: GridLayout {
        id: monthCol

        required property var grid

        columns: 8
        rowSpacing: 1
        columnSpacing: 0

        // Flattened weekday-header + 6 week rows, in row-major order: corner
        // blank, Mo..Su, then per week a week-number cell and its 7 days.
        function cells(): var {
            const wdays = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"];
            const out = [
                {
                    kind: "corner"
                }
            ];
            for (let i = 0; i < 7; i++)
                out.push({
                    kind: "wday",
                    label: wdays[i],
                    weekend: i >= 5
                });
            for (const week of monthCol.grid.weeks) {
                out.push({
                    kind: "wknum",
                    num: week.num
                });
                for (const d of week.days)
                    out.push({
                        kind: "day",
                        day: d.day,
                        other: d.other,
                        today: d.today,
                        weekend: d.weekend
                    });
            }
            return out;
        }

        Repeater {
            model: monthCol.cells()

            delegate: Item {
                id: cell

                required property var modelData

                Layout.preferredWidth: 26
                Layout.preferredHeight: modelData.kind === "day" ? 24 : 18

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.rowRadius
                    visible: cell.modelData.today === true && !cell.modelData.other
                    color: root.accent
                }

                Text {
                    anchors.centerIn: parent
                    visible: cell.modelData.kind !== "corner"
                    text: cell.modelData.kind === "wday" ? cell.modelData.label : cell.modelData.kind === "wknum" ? cell.modelData.num : (cell.modelData.day ?? "")
                    font.family: Theme.ui
                    font.pixelSize: cell.modelData.kind === "day" ? 12 : 10
                    font.features: { "tnum": 1 }
                    font.weight: cell.modelData.kind === "wday" || (cell.modelData.today === true && !cell.modelData.other) ? Font.DemiBold : Font.Normal
                    color: {
                        if (cell.modelData.kind === "wday" || cell.modelData.kind === "wknum")
                            return Theme.faint;
                        if (cell.modelData.today && !cell.modelData.other)
                            return Theme.ink;
                        if (cell.modelData.other)
                            return Theme.faint;
                        if (cell.modelData.weekend)
                            return Theme.dim;
                        return Theme.fg;
                    }
                }
            }
        }
    }

    component Arrow: Text {
        id: arrow

        signal clicked

        color: arrowHover.hovered ? Theme.soften(root.accent) : Theme.dim
        font.family: Theme.icon
        font.pixelSize: 14

        HoverHandler {
            id: arrowHover

            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            onSingleTapped: arrow.clicked()
        }
    }

    component MonthTitle: Text {
        Layout.fillWidth: true
        leftPadding: 26
        color: Theme.fg
        font.family: Theme.ui
        font.weight: Font.DemiBold
        font.pixelSize: 12
    }

    ColumnLayout {
        spacing: 10

        PanelTitle {
            glyph: Config.glyph.calendar
            text: "Calendar"
            accent: root.accent

            Arrow {
                text: Config.glyph.larrow
                onClicked: root.offset -= 1
            }
            Arrow {
                text: Config.glyph.rarrow
                onClicked: root.offset += 1
            }
        }

        RowLayout {
            spacing: 20

            ColumnLayout {
                spacing: 6

                MonthTitle {
                    text: root.leftGrid.title + " " + root.leftGrid.year
                }
                MonthColumn {
                    grid: root.leftGrid
                }
            }
            ColumnLayout {
                spacing: 6

                MonthTitle {
                    text: root.rightGrid.title + " " + root.rightGrid.year
                }
                MonthColumn {
                    grid: root.rightGrid
                }
            }
        }
    }
}

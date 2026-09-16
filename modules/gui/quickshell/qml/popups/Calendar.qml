// Two-month calendar. calendar.py emitted this as data (day/other/today/weekend
// flags, ISO week numbers) and let CSS draw it; here the same grid is computed
// straight from JS Date, no process involved.
import QtQuick
import QtQuick.Layouts
import qs
import qs.components

PopupPanel {
    id: root

    // Months from the current one; both panes move together off one offset.
    property int offset: 0

    readonly property var leftGrid: monthGrid(offset)
    readonly property var rightGrid: monthGrid(offset + 1)

    onOpenChanged: if (!open)
        offset = 0

    function monthGrid(delta: int): var {
        const now = new Date();
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
                    radius: 6
                    visible: cell.modelData.kind === "day"
                    color: cell.modelData.today ? Theme.aqua : (cell.modelData.weekend ? Theme.alpha(Theme.orange, 0.10) : "transparent")
                }

                Text {
                    anchors.centerIn: parent
                    visible: cell.modelData.kind !== "corner"
                    text: cell.modelData.kind === "wday" ? cell.modelData.label : cell.modelData.kind === "wknum" ? cell.modelData.num : (cell.modelData.day ?? "")
                    font.family: Theme.ui
                    font.pixelSize: cell.modelData.kind === "day" ? 12 : 11
                    font.bold: cell.modelData.kind === "wday" || cell.modelData.today === true
                    color: {
                        if (cell.modelData.kind === "wday")
                            return cell.modelData.weekend ? Theme.orange : Theme.grey;
                        if (cell.modelData.kind === "wknum")
                            return Theme.grey;
                        if (cell.modelData.today)
                            return Theme.ink;
                        if (cell.modelData.other)
                            return Theme.grey;
                        if (cell.modelData.weekend)
                            return Theme.orange;
                        return Theme.fg;
                    }
                }
            }
        }
    }

    ColumnLayout {
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            spacing: 0

            Text {
                text: Config.glyph.larrow
                color: leftArrow.hovered ? Theme.orange : Theme.aqua
                font.family: Theme.mono
                font.pixelSize: 16

                HoverHandler {
                    id: leftArrow
                }
                TapHandler {
                    onSingleTapped: root.offset -= 1
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 0

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: root.leftGrid.title + " " + root.leftGrid.year
                    color: Theme.yellow
                    font.family: Theme.ui
                    font.bold: true
                    font.pixelSize: 15
                }
                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: root.rightGrid.title + " " + root.rightGrid.year
                    color: Theme.yellow
                    font.family: Theme.ui
                    font.bold: true
                    font.pixelSize: 15
                }
            }

            Text {
                text: Config.glyph.rarrow
                color: rightArrow.hovered ? Theme.orange : Theme.aqua
                font.family: Theme.mono
                font.pixelSize: 16

                HoverHandler {
                    id: rightArrow
                }
                TapHandler {
                    onSingleTapped: root.offset += 1
                }
            }
        }

        RowLayout {
            spacing: 20

            MonthColumn {
                grid: root.leftGrid
            }
            MonthColumn {
                grid: root.rightGrid
            }
        }
    }
}

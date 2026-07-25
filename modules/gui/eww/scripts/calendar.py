#!/usr/bin/env python3
"""Month-grid emitter for the eww calendar popup, giving full control over the
today marker (GtkCalendar refuses to render a legible today pill).

Modes:
  calendar <offset>       emit one month's grid JSON (offset in months)
  calendar push <base>    recompute both panes (base, base+1) + push into eww
                          vars cal_offset/cal_left/cal_right, for the two-month
                          sliding window and its nav buttons.

Grid JSON:
  {"title":"July","month":7,"year":2026,
   "weeks":[ {"num":27,"days":[ {"day":1,"other":true,"today":false,
                                 "weekend":false}, ...7 ]}, ...6 ]}
Weeks start Monday (ISO) with ISO week numbers; `other` = adjacent-month spill;
`today` = the real current date; `weekend` = Saturday or Sunday.
"""

import json
import os
import subprocess
import sys
from datetime import date, timedelta

WEEKS = 6
EWW = os.environ.get("EWW_BIN", "eww")


def add_months(d: date, months: int) -> date:
    total = d.year * 12 + (d.month - 1) + months
    return date(total // 12, total % 12 + 1, 1)


def grid(offset: int) -> dict:
    today = date.today()
    first = add_months(today.replace(day=1), offset)
    # Grid start: the Monday on/before the 1st.
    start = first - timedelta(days=first.weekday())

    weeks = []
    for w in range(WEEKS):
        days = []
        for d in range(7):
            cur = start + timedelta(days=w * 7 + d)
            days.append({
                "day": cur.day,
                "other": cur.month != first.month,
                "today": cur == today,
                "weekend": cur.weekday() >= 5,
            })
        monday = start + timedelta(days=w * 7)
        weeks.append({"num": monday.isocalendar()[1], "days": days})

    return {
        "title": first.strftime("%B"),
        "month": first.month,
        "year": first.year,
        "weeks": weeks,
    }


def main(argv: list[str]) -> int:
    if argv[:1] == ["push"]:
        base = int(argv[1]) if len(argv) > 1 else 0
        subprocess.run(
            [
                EWW, "update",
                f"cal_offset={base}",
                f"cal_left={json.dumps(grid(base), separators=(',', ':'))}",
                f"cal_right={json.dumps(grid(base + 1), separators=(',', ':'))}",
            ],
            stderr=subprocess.DEVNULL,
            check=False,
        )
    else:
        offset = int(argv[0]) if argv else 0
        print(json.dumps(grid(offset), separators=(",", ":")), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

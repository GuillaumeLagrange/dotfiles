#!/usr/bin/env bash
# Custom month-grid emitter for the eww calendar popup, giving full control over
# the today marker (GtkCalendar refuses to render a legible today pill).
#
# Modes:
#   calendar-eww <offset>       emit one month's grid JSON (offset in months)
#   calendar-eww push <base>    recompute both panes (base, base+1) + push into
#                               eww vars cal_offset/cal_left/cal_right, for the
#                               two-month sliding window and its nav buttons.
#
# Grid JSON:
#   {"title":"July","month":7,"year":2026,
#    "weeks":[ {"num":27,"days":[ {"day":1,"other":true,"today":false}, …7 ]}, …6 ]}
# Weeks start Monday (ISO) with ISO week numbers; `other` = adjacent-month spill;
# `today` = the real current date.
set -euo pipefail

grid() {
  local offset="$1"
  local first today title m start
  first=$(date -d "$(date +%Y-%m-01) +${offset} month" +%Y-%m-%d)
  today=$(date +%Y-%m-%d)
  title=$(date -d "$first" +'%B')
  m=$(date -d "$first" +%m)

  # Grid start: the Monday on/before the 1st. %u = ISO weekday (Mon=1..Sun=7).
  local dow
  dow=$(date -d "$first" +%u)
  start=$(date -d "$first -$((dow - 1)) day" +%Y-%m-%d)

  local weeks_json="[" w d idx cur dnum cmonth other istoday weeknum days_json
  for w in 0 1 2 3 4 5; do
    days_json="["
    weeknum=""
    for d in 0 1 2 3 4 5 6; do
      idx=$((w * 7 + d))
      cur=$(date -d "$start +$idx day" +%Y-%m-%d)
      dnum=$(date -d "$cur" +%-d)
      cmonth=$(date -d "$cur" +%m)
      other=false; [ "$cmonth" != "$m" ] && other=true
      istoday=false; [ "$cur" = "$today" ] && istoday=true
      [ "$d" -eq 0 ] && weeknum=$(date -d "$cur" +%V)
      days_json+=$(printf '{"day":%d,"other":%s,"today":%s},' "$dnum" "$other" "$istoday")
    done
    days_json="${days_json%,}]"
    weeks_json+=$(printf '{"num":%d,"days":%s},' "$((10#$weeknum))" "$days_json")
  done
  weeks_json="${weeks_json%,}]"

  printf '{"title":"%s","month":%d,"year":%d,"weeks":%s}\n' \
    "$title" "$((10#$m))" "$(date -d "$first" +%Y)" "$weeks_json"
}

if [ "${1:-}" = "push" ]; then
  base="${2:-0}"
  eww update \
    "cal_offset=$base" \
    "cal_left=$(grid "$base")" \
    "cal_right=$(grid "$((base + 1))")" 2>/dev/null || true
else
  grid "${1:-0}"
fi

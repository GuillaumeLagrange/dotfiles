#!/usr/bin/env bash
# Battery capacity, charging state, and a time-to-full/empty estimate.
# Emits: {"capacity":93,"charging":false,"class":"...","text":"...","tooltip":"..."}
set -euo pipefail

# Discharging glyphs by charge tier (waybar format-icons order).
ICONS=("󰂎" "󱊡" "󱊢" "󱊣")
ICON_BOLT="󱐋"

bat=$(for b in /sys/class/power_supply/BAT*; do [ -e "$b" ] && echo "$b" && break; done)
if [ -z "${bat:-}" ]; then
  echo '{"capacity":0,"charging":false,"class":"hidden","text":"","tooltip":""}'
  exit 0
fi

capacity=$(cat "$bat/capacity")
status=$(cat "$bat/status")

charging=false
class="discharging"
case "$status" in
  Charging|Full) charging=true; class="charging" ;;
esac
if [ "$capacity" -le 15 ] && [ "$charging" = false ]; then
  class="critical"
fi

idx=$(( capacity * (${#ICONS[@]} - 1) / 100 ))
[ "$idx" -ge "${#ICONS[@]}" ] && idx=$(( ${#ICONS[@]} - 1 ))
icon="${ICONS[$idx]}"
if [ "$charging" = true ]; then
  text="$ICON_BOLT $icon ${capacity}%"
else
  text="$icon ${capacity}%"
fi

# Time estimate from energy/charge counters (µWh & µW, or µAh & µA).
# rate = power_now or current_now; remaining depends on direction.
read_val() { [ -r "$bat/$1" ] && cat "$bat/$1" || echo ""; }
energy_now=$(read_val energy_now); energy_full=$(read_val energy_full); power_now=$(read_val power_now)
charge_now=$(read_val charge_now); charge_full=$(read_val charge_full); current_now=$(read_val current_now)

now=""; full=""; rate=""
if [ -n "$energy_now" ] && [ -n "$power_now" ]; then
  now="$energy_now"; full="$energy_full"; rate="$power_now"
elif [ -n "$charge_now" ] && [ -n "$current_now" ]; then
  now="$charge_now"; full="$charge_full"; rate="$current_now"
fi

eta=""
if [ -n "$rate" ] && [ "$rate" -gt 0 ]; then
  if [ "$charging" = true ]; then
    remaining=$(( full - now )); label="until full"
  else
    remaining="$now"; label="remaining"
  fi
  if [ "$remaining" -gt 0 ]; then
    mins=$(( remaining * 60 / rate ))
    h=$(( mins / 60 )); m=$(( mins % 60 ))
    eta=$(printf "%dh%02dm %s" "$h" "$m" "$label")
  fi
fi

state_line="Battery ${capacity}% — ${status}"
tooltip="$state_line"
[ -n "$eta" ] && tooltip="${state_line}"$'\n'"${eta}"

jq -cn --arg t "$text" --arg c "$class" --arg tip "$tooltip" \
  --argjson cap "$capacity" --argjson ch "$charging" \
  '{capacity:$cap,charging:$ch,class:$c,text:$t,tooltip:$tip}'

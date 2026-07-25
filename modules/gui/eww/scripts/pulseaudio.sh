#!/usr/bin/env bash
# Default sink volume + mute state.
# Long-running `deflisten` source: emit once, then re-emit whenever pulse
# reports a sink change (pactl subscribe), so the badge is event-driven
# instead of polled.
# Emits: {"volume":34,"muted":false,"text":"󰕾 34%","class":"...","sink":"AirPods"}
set -euo pipefail

# Volume glyphs by level.
ICON_LOW="󰕿"
ICON_MID="󰖀"
ICON_HIGH="󰕾"
ICON_MUTED="󰝟"

emit() {
  local vol muted pct icon text class sink
  vol=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null || echo "Volume: 0.00")
  muted=false
  [[ "$vol" == *"[MUTED]"* ]] && muted=true
  pct=$(awk '{printf "%d", $2 * 100}' <<<"$vol")

  # Friendly name of the current output device, for the tooltip.
  sink=$(wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null \
    | sed -n 's/.*node\.description = "\(.*\)"/\1/p' | head -1)
  [ -z "$sink" ] && sink="Default sink"

  if [ "$muted" = true ]; then
    text="$ICON_MUTED ${pct}%"; class="muted"
  else
    if [ "$pct" -lt 34 ]; then icon="$ICON_LOW"
    elif [ "$pct" -lt 67 ]; then icon="$ICON_MID"
    else icon="$ICON_HIGH"; fi
    text="$icon ${pct}%"; class="unmuted"
  fi

  jq -cn --arg t "$text" --arg c "$class" --arg s "$sink" --argjson v "$pct" --argjson m "$muted" \
    '{volume:$v,muted:$m,text:$t,class:$c,sink:$s}'
}

emit
# `pactl subscribe` streams "Event 'change' on sink #N"; repaint on any sink
# event (volume, mute, default-sink switch). Debounce-free: emit is cheap.
pactl subscribe 2>/dev/null | while read -r line; do
  case "$line" in
    *"on sink"*|*"on server"*) emit ;;
  esac
done

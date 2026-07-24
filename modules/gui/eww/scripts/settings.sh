#!/usr/bin/env bash
# Settings-drawer state + actions for the eww bar, mirroring the behavior of
# waybar's group/settings (gear + idle + dnd + power-profile).
#
# State is pushed into eww vars (idlest/dndst/profst/settings) rather than
# polled: user toggles push right after acting, and external power-profile
# changes are caught by a gdbus watcher (the `watch` subcommand). The gear
# badge summarizes active toggles (idle / dnd) and tints to the power profile.
#
# Glyphs are written as Unicode codepoints (printf '\uXXXX') so the source stays
# ASCII — nerd-font bytes have been silently stripped by edits before.
set -euo pipefail

ICON_GEAR=$(printf '\U000f0493')  # md-cog (metrically centered, unlike fa-cog)
ICON_IDLE=$(printf '\uf06e')  # fa-eye
ICON_DND=$(printf '\uf1f6')   # fa-bell-slash

IDLE_INHIBIT="${IDLE_INHIBIT_BIN:-idle-inhibit}"

dnd_on() { makoctl mode 2>/dev/null | grep -qw do-not-disturb; }
idle_on() { [ "$("$IDLE_INHIBIT" status)" = "on" ]; }
profile() { powerprofilesctl get 2>/dev/null || echo balanced; }

profile_icon() {
  case "$1" in
    performance) printf '\U000f04c5' ;; # md-speedometer
    power-saver) printf '\U000f0f86' ;; # md-gauge-low
    *)           printf '\U000f0f85' ;; # md-gauge
  esac
}

emit_gear() {
  local badges=()
  idle_on && badges+=("$ICON_IDLE")
  dnd_on && badges+=("$ICON_DND")
  local text="${badges[*]:+${badges[*]} }$ICON_GEAR"
  jq -cn --arg t "$text" --arg c "$(profile)" '{text:$t,class:$c}'
}
emit_idle()    { idle_on && s=on || s=off; jq -cn --arg s "$s" '{on:($s=="on"),class:$s}'; }
emit_dnd()     { dnd_on  && s=on || s=off; jq -cn --arg s "$s" '{on:($s=="on"),class:$s}'; }
emit_profile() { local p; p=$(profile); jq -cn --arg p "$p" --arg i "$(profile_icon "$p")" '{profile:$p,icon:$i}'; }

# Push all four settings vars into the running eww daemon in one call.
push() {
  eww update \
    "settings=$(emit_gear)" \
    "idlest=$(emit_idle)" \
    "dndst=$(emit_dnd)" \
    "profst=$(emit_profile)" 2>/dev/null || true
}

case "${1:-gear}" in
  gear)    emit_gear ;;
  idle)    emit_idle ;;
  dnd)     emit_dnd ;;
  profile) emit_profile ;;
  push)    push ;;
  toggle-idle)
    "$IDLE_INHIBIT" toggle
    push
    ;;
  toggle-dnd)
    makoctl mode -t do-not-disturb >/dev/null 2>&1 || true
    push
    ;;
  profile-set)
    powerprofilesctl set "${2:-balanced}" 2>/dev/null || true
    push
    ;;
  profile-up)
    # Toward more performance: power-saver -> balanced -> performance.
    case "$(profile)" in
      power-saver) next=balanced ;;
      balanced)    next=performance ;;
      *)           next=performance ;;
    esac
    powerprofilesctl set "$next" 2>/dev/null || true
    push
    ;;
  profile-down)
    # Toward more saving: performance -> balanced -> power-saver.
    case "$(profile)" in
      performance) next=balanced ;;
      balanced)    next=power-saver ;;
      *)           next=power-saver ;;
    esac
    powerprofilesctl set "$next" 2>/dev/null || true
    push
    ;;
  watch)
    # Long-running service: seed the initial state, then repaint on external
    # profile changes. powerprofilesctl has no watch subcommand, so monitor the
    # D-Bus property. The daemon emits PropertiesChanged on two paths per
    # change; matching one keeps it to a single push.
    #
    # Wait for the eww daemon to accept commands before the first push, so
    # startup state isn't lost to a race with the bar coming up.
    for _ in $(seq 1 50); do
      eww ping >/dev/null 2>&1 && break
      sleep 0.2
    done
    push
    gdbus monitor --system --dest net.hadess.PowerProfiles \
      | grep --line-buffered "^/net/hadess/PowerProfiles.*ActiveProfile" \
      | while read -r _; do push; done
    ;;
esac

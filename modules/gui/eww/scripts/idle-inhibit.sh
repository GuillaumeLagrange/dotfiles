#!/usr/bin/env bash
# Idle-inhibit toggle for the eww bar. eww can't hold the Wayland
# zwp_idle_inhibit protocol the way waybar's native module does, so this holds
# a systemd idle lock instead: your swayidle timeouts and suspend-then-hibernate
# are driven through systemd/logind, so a held "idle" lock blocks them.
#
# A backgrounded `systemd-inhibit --what=idle sleep infinity` is the lock; its
# PID is tracked in a runtime-dir pidfile so status/toggle survive across bar
# restarts (and the reset service clears it on (re)start to match waybar's
# deactivate-on-start behavior).
set -euo pipefail

STATEDIR="${XDG_RUNTIME_DIR:-/tmp}"
PIDFILE="$STATEDIR/eww-idle-inhibit.pid"

is_on() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

case "${1:-status}" in
  status)
    if is_on; then echo "on"; else echo "off"; fi
    ;;
  toggle)
    if is_on; then
      kill "$(cat "$PIDFILE")" 2>/dev/null || true
      rm -f "$PIDFILE"
    else
      systemd-inhibit --what=idle --who="eww-bar" --why="Idle inhibited from bar" \
        --mode=block sleep infinity &
      echo $! > "$PIDFILE"
    fi
    ;;
  reset)
    if is_on; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; fi
    rm -f "$PIDFILE"
    ;;
esac

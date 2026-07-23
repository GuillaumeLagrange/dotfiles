#!/usr/bin/env bash
# Start the eww daemon and keep one bar window open per connected niri output,
# mirroring waybar's output = ["*"] (a bar on every monitor, auto-tracking
# dock/undock). Runs in the foreground as the systemd service's main process.
#
# niri exposes no output-hotplug event on its stream, so unlike waybar (which
# tracks outputs natively) we reconcile by polling `niri msg outputs`: open a
# bar for any newly connected output, close it when the output disappears.
set -euo pipefail

eww daemon --no-daemonize &
daemon_pid=$!
trap 'eww kill 2>/dev/null || true; kill "$daemon_pid" 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  eww ping >/dev/null 2>&1 && break
  sleep 0.1
done

connected_outputs() {
  # A connected output has a non-null logical region; disconnected ones linger
  # in the map with logical=null and must not get a bar.
  niri msg --json outputs | jq -r 'to_entries[] | select(.value.logical != null) | .value.name'
}

declare -A open=()

reconcile() {
  local -A want=()
  local out
  while read -r out; do
    [ -z "$out" ] && continue
    want["$out"]=1
    if [ -z "${open[$out]:-}" ]; then
      eww open bar --id "bar-$out" --screen "$out" --arg monitor="$out" 2>/dev/null \
        && open["$out"]=1
    fi
  done < <(connected_outputs)

  for out in "${!open[@]}"; do
    if [ -z "${want[$out]:-}" ]; then
      eww close "bar-$out" 2>/dev/null || true
      unset 'open[$out]'
    fi
  done
}

while true; do
  reconcile
  sleep 3
done

#!/usr/bin/env bash
# Free space on the root filesystem, mirroring waybar's disk {free}
# (one decimal, binary units with the iB suffix, e.g. "123.5GiB"). The tooltip
# mirrors waybar's default disk tooltip: used/total and percentage on the mount.
# Emits: {"free":"123.5GiB","tooltip":"..."}
set -euo pipefail

human() { # KiB -> "123.5GiB" (integer for bytes, one decimal above)
  awk -v k="$1" 'BEGIN {
    b = k * 1024
    split("B KiB MiB GiB TiB PiB", u, " ")
    i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    printf (i == 1 ? "%.0f%s" : "%.1f%s"), b, u[i]
  }'
}

read -r avail_kib used_kib total_kib pcent \
  < <(df -k --output=avail,used,size,pcent / | tail -1 | tr -d '%')

free=$(human "$avail_kib")
tooltip="$(human "$used_kib") used out of $(human "$total_kib") on / (${pcent}%)"

jq -cn --arg f "$free" --arg tip "$tooltip" '{free:$f,tooltip:$tip}'

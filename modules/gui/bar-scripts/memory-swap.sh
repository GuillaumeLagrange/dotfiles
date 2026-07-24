#!/usr/bin/env bash
# Emit a waybar JSON payload combining RAM usage % with per-device swap usage,
# so zram (in-RAM compressed) and disk swap can be told apart at a glance.
set -euo pipefail

# --- RAM percentage, computed the way most tools show "used" ---
mem_total=0
mem_available=0
while read -r key value _; do
  case "$key" in
    MemTotal:) mem_total=$value ;;
    MemAvailable:) mem_available=$value ;;
  esac
done < /proc/meminfo

ram_pct=0
if [ "$mem_total" -gt 0 ]; then
  ram_pct=$(( (mem_total - mem_available) * 100 / mem_total ))
fi

# --- per-device swap, summed by class (zram vs everything else = disk) ---
# /proc/swaps "Used" is the uncompressed page count, in KiB.
zram_used_kib=0
disk_used_kib=0
while read -r filename _ _ used _; do
  case "$filename" in
    Filename) continue ;;                 # header row
    /dev/zram*) zram_used_kib=$(( zram_used_kib + used )) ;;
    *) disk_used_kib=$(( disk_used_kib + used )) ;;
  esac
done < /proc/swaps

# --- actual RAM the zram devices occupy (compressed), from mm_stat ---
# Field 3 of /sys/block/zramN/mm_stat is mem_used_total, in bytes.
zram_compressed_kib=0
for mm in /sys/block/zram*/mm_stat; do
  [ -r "$mm" ] || continue
  read -r _ _ mem_used_total _ < "$mm"
  zram_compressed_kib=$(( zram_compressed_kib + mem_used_total / 1024 ))
done

human() {
  # KiB -> human GiB/MiB with one decimal, no external deps
  local kib=$1
  if [ "$kib" -ge 1048576 ]; then
    awk -v k="$kib" 'BEGIN { printf "%.1fG", k / 1048576 }'
  else
    awk -v k="$kib" 'BEGIN { printf "%.0fM", k / 1024 }'
  fi
}

zram_raw_h=$(human "$zram_used_kib")
zram_real_h=$(human "$zram_compressed_kib")
disk_h=$(human "$disk_used_kib")

# Disk spill is the signal worth surfacing: past zram, hitting slow storage.
# Hide the disk slot entirely until something actually lands there.
class="ok"

# zram shows uncompressed pages -> real RAM cost, e.g. "5.2G->1.3G".
text="&#xf061a; ${ram_pct}% &#xf140b;${zram_raw_h}"
tooltip="RAM ${ram_pct}% used\nzram ${zram_raw_h} pages → ${zram_real_h} in RAM\ndisk swap ${disk_h}"

printf '{"text": "%s", "class": "%s", "tooltip": "%s"}\n' "$text" "$class" "$tooltip"

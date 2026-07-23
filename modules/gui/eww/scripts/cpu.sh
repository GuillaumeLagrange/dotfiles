#!/usr/bin/env bash
# Aggregate CPU usage % plus a per-core breakdown for the tooltip, sampled over
# a short delta of /proc/stat. Emits: {"usage":42,"tooltip":"core0 12%\n..."}
set -euo pipefail

# Snapshot every cpu line (aggregate "cpu" + per-core "cpuN") as "busy idle".
snapshot() {
  while read -r name user nice system idle iowait irq softirq steal _; do
    case "$name" in
      cpu | cpu[0-9]*)
        local idle_all=$((idle + iowait))
        local busy=$((user + nice + system + irq + softirq + steal))
        echo "$name $((busy + idle_all)) $idle_all"
        ;;
    esac
  done < /proc/stat
}

declare -A t1 i1 t2 i2
while read -r name total idle; do t1[$name]=$total; i1[$name]=$idle; done < <(snapshot)
sleep 0.5
while read -r name total idle; do t2[$name]=$total; i2[$name]=$idle; done < <(snapshot)

pct() { # $1=name -> usage %
  local dt=$(( t2[$1] - t1[$1] )) di=$(( i2[$1] - i1[$1] ))
  [ "$dt" -le 0 ] && { echo 0; return; }
  echo $(( (dt - di) * 100 / dt ))
}

usage=$(pct cpu)

# Pad each core index to the widest one so the "%" column stays aligned when
# core counts cross into two digits (cpu0 … cpu11).
width=0
for name in "${!t2[@]}"; do
  [ "$name" = cpu ] && continue
  n=${#name}
  [ "$n" -gt "$width" ] && width=$n
done

tooltip=""
for name in "${!t2[@]}"; do
  [ "$name" = cpu ] && continue
  tooltip+=$(printf '%-*s %s%%' "$width" "${name}:" "$(pct "$name")")$'\n'
done
# Sort core lines (cpu0, cpu1, …) and trim the trailing newline.
tooltip=$(printf '%s' "$tooltip" | sort -V)

jq -cn --argjson u "$usage" --arg tip "$tooltip" '{usage:$u,tooltip:$tip}'

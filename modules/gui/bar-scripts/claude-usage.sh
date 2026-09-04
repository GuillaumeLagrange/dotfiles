#!/usr/bin/env bash
# Claude Code usage for the bar — formats `omp usage -j` (omp owns fetching,
# caching and token refresh).
set -uo pipefail

OMP_BIN="${OMP_BIN:-$HOME/.local/bin/omp}"

case "${1:-}" in
  --force-refresh | --restart)
    "$OMP_BIN" usage invalidate --provider anthropic >/dev/null 2>&1
    ;;
esac

if ! data=$("$OMP_BIN" usage -j --provider anthropic 2>/dev/null); then
  printf '{"text":"󰜡 Err","tooltip":"omp usage failed","class":"critical"}\n'
  exit 0
fi

jq -c '
  def pad2: tostring | if length < 2 then "0" + . else . end;
  def eta:
    if . == null then "--"
    else (. / 1000 - now | floor) as $d
    | if $d <= 0 then "0m"
      elif $d >= 86400 then "\($d / 86400 | floor)d\(($d % 86400) / 3600 | floor | pad2)h"
      elif $d >= 3600 then "\($d / 3600 | floor)h\(($d % 3600) / 60 | floor | pad2)m"
      else "\($d / 60 | floor)m"
      end
    end;
  def clock($fmt):
    if . == null then "--" else (. / 1000 | floor | strflocaltime($fmt)) end;
  def window($id; $prefix; $fmt):
    (([.reports[].limits[] | select(.window.id == $id)] | sort_by(.amount.usedFraction) | last) // {})
    | ((.window // {}).resetsAt) as $r
    | { pct: ((.amount.usedFraction // 0) * 100 | round), eta: ($r | eta),
        at: (if $r == null then "--" else "\($prefix) \($r | clock($fmt))" end) };

  window("5h"; "at"; "%H:%M") as $fh
  | window("7d"; "on"; "%a %H:%M") as $sd
  | {
      text: "󰜡 " + (
        if $sd.pct >= 100 then $sd.eta
        elif $fh.pct >= 100 then $fh.eta
        else "\($fh.pct)%" end
      ),
      tooltip: "Claude Code Usage\n━━━━━━━━━━━━━━━━━━━━━━━━\n5h:  \($fh.pct)%  \($fh.eta) (\($fh.at))\n7d:  \($sd.pct)%  \($sd.eta) (\($sd.at))",
      class: (if $fh.pct >= 80 then "high" elif $fh.pct >= 50 then "mid" else "low" end),
      percentage: $fh.pct,
    }
' <<<"$data"

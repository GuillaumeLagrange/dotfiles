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
  def rpad($n): tostring | . + ("               "[0:$n - length] // "");
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
  # `f` selects the limits of one window; the tightest one wins when a plan
  # reports several. Missing window (account without that limit) => null, so
  # the tooltip line is dropped instead of rendering zeroes.
  def window(f; $label; $prefix; $fmt):
    (([.reports[].limits[] | select(f)] | sort_by(.amount.usedFraction) | last) // null) as $l
    | if $l == null then null
      else (($l.window // {}).resetsAt) as $r
      | { label: $label, pct: (($l.amount.usedFraction // 0) * 100 | round),
          eta: ($r | eta),
          at: (if $r == null then "--" else "\($prefix) \($r | clock($fmt))" end) }
      end;

  window(.id | endswith(":5h"); "5h"; "at"; "%H:%M") as $fh
  | window(.id | endswith(":7d"); "7d"; "on"; "%a %H:%M") as $sd
  | window(.id | endswith(":7d:fable"); "fable"; "on"; "%a %H:%M") as $fb
  | [$fh, $sd, $fb | select(. != null)] as $ws
  | (($fh.pct) // 0) as $pct
  | {
      text: "󰜡 " + (
        ([$ws[] | select(.pct >= 100)] | first) as $full
        | if $full != null then $full.eta else "\($pct)%" end
      ),
      tooltip: (["Claude Code Usage", "━━━━━━━━━━━━━━━━━━━━━━━━"]
        + [$ws[] | "\(.label + ":" | rpad(7))\(.pct)%  \(.eta) (\(.at))"]
        | join("\n")),
      class: (if $pct >= 80 then "high" elif $pct >= 50 then "mid" else "low" end),
      percentage: $pct,
    }
' <<<"$data"

#!/usr/bin/env bash
# Single niri event-stream tap feeding the whole left side of the bar.
# Emits one JSON object per relevant event, consumed by eww `deflisten`:
#   {"workspaces":[...], "by_output":{"<name>":{"title":..,"windows":{..}}}}
# `workspaces` is the full list (each bar filters to its own output); title and
# dots are per-output so each monitor's bar shows its own visible workspace.
# Keeping it all on one stream means every bar repaints from a single niri
# subscription.
set -euo pipefail

emit() {
  # Rebuild the aggregate snapshot from two synchronous queries. niri's
  # event payloads are deltas; re-querying is simpler and cheap here.
  local workspaces windows
  workspaces=$(niri msg --json workspaces)
  windows=$(niri msg --json windows)

  jq -cn --argjson ws "$workspaces" --argjson wins "$windows" '
    # Windows on a given workspace, ordered left-to-right in the scroll layout.
    def wins_of($wid): [ $wins[] | select(.workspace_id == $wid) ]
      | sort_by((.layout.pos_in_scrolling_layout // [0])[0]);

    {
      # Named workspaces only, sorted by output then index, for the buttons.
      workspaces: (
        [ $ws[] | select(.name != null) ]
        | sort_by([.output, .idx])
        | map(. as $w | {
            id, idx, name, output,
            is_active,          # visible on its output
            is_focused,         # keyboard focus (the "current" one)
            is_urgent: (.is_urgent // false),
            is_empty: ($w.active_window_id == null
                       and (wins_of($w.id) | length) == 0)
          })
      ),
      # Per-output title + window dots, keyed by connector name. Each output has
      # exactly one active (visible) workspace; that is the one the bar shows.
      by_output: (
        [ $ws[] | select(.is_active and .output != null) ]
        | map(. as $aw | wins_of($aw.id) as $awins | {
            key: $aw.output,
            value: {
              title: (($awins | map(select(.id == ($aw.active_window_id // -1))) | first).title // ""),
              windows: {
                count: ($awins | length),
                dots: ([ $awins[] | if .id == ($aw.active_window_id // -1) then "●" else "○" end ] | join(" "))
              }
            }
          })
        | from_entries
      )
    }
  '
}

# Prime once so the bar has data before the first event.
emit

niri msg --json event-stream | while read -r line; do
  case "$line" in
    *WorkspacesChanged*|*WorkspaceActivated*|*WorkspaceActiveWindowChanged*|\
    *WindowOpenedOrChanged*|*WindowClosed*|*WindowFocusChanged*|*WindowsChanged*)
      emit
      ;;
  esac
done

set -euo pipefail

# Close every tiled pane but the focused one in the tab of the pane the keybind ran from (a
# background Run sets ZELLIJ_PANE_ID to that pane).

zellij action list-panes --json | jq -r --argjson id "$ZELLIJ_PANE_ID" '
  first(.[] | select(.is_plugin == false and .id == $id)).tab_id as $tab
  | [.[] | select(.tab_id == $tab and .is_floating == false and .is_suppressed == false and .is_selectable)]
  | first(.[] | select(.is_focused)) as $keep
  | .[] | select(.id != $keep.id or .is_plugin != $keep.is_plugin)
  | "\(if .is_plugin then "plugin" else "terminal" end)_\(.id)"' |
  while read -r pane; do
    zellij action close-pane --pane-id "$pane"
  done

set -euo pipefail

# Close every tab but the one this pane (run from a keybind) is in.

keep=$(zellij action list-panes --json | jq -er --argjson id "$ZELLIJ_PANE_ID" \
  'first(.[] | select(.is_plugin == false and .id == $id)) | .tab_id')

zellij action list-tabs --json | jq -r --argjson keep "$keep" '.[] | select(.tab_id != $keep) | .tab_id' |
  while read -r tab; do
    zellij action close-tab-by-id "$tab"
  done

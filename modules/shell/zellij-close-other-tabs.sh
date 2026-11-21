set -euo pipefail

# Close every tab but the one holding the pane the keybind ran from (a background Run sets
# ZELLIJ_PANE_ID to that pane).

keep=$(zellij action list-panes --json | jq -er --argjson id "$ZELLIJ_PANE_ID" \
  'first(.[] | select(.is_plugin == false and .id == $id)) | .tab_id')

zellij action list-tabs --json | jq -r --argjson keep "$keep" '.[] | select(.tab_id != $keep) | .tab_id' |
  while read -r tab; do
    zellij action close-tab-by-id "$tab"
  done

set -euo pipefail

# Resolve the display name for a tmux window based on a pane's current path.
# Outputs the git root basename (with branch icon) or the path with ~ substitution.
#
# Usage: tmux-window-name <pane_path>

pane_path="${1:?Usage: tmux-window-name <pane_path>}"

git_root=$(cd "$pane_path" 2>/dev/null && @git@ rev-parse --show-toplevel 2>/dev/null || echo "")

if [[ -n "$git_root" ]]; then
  echo " $(basename "$git_root")"
else
  display_path="$pane_path"
  if [[ "$display_path" == "$HOME"* ]]; then
    display_path="~${display_path#$HOME}"
  fi
  echo "$display_path"
fi

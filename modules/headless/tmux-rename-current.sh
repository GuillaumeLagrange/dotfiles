set -euo pipefail

# Rename the current tmux window based on git repo or current directory.

pane_path=$(tmux display-message -p "#{pane_current_path}")
display_path=$(tmux-window-name "$pane_path")
current_name=$(tmux display-message -p "#{window_name}")

if [[ "$current_name" != "$display_path" ]]; then
  tmux rename-window "$display_path"
fi

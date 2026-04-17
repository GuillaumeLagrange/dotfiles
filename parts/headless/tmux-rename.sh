set -euo pipefail

# Rename all windows in a tmux session based on git repos or current directory.

SESSION="${1:-$(@tmux@ display-message -p '#S')}"

echo "Renaming windows in session '$SESSION' based on git repos or current directory"

@tmux@ list-windows -t "$SESSION" -F "#{window_index}" | while read -r window_index; do
  pane_path=$(@tmux@ display-message -t "$SESSION:$window_index.0" -p "#{pane_current_path}")
  display_path=$(@tmux-window-name@ "$pane_path")
  current_name=$(@tmux@ display-message -t "$SESSION:$window_index" -p "#{window_name}")

  if [[ "$current_name" != "$display_path" ]]; then
    echo "  Window $window_index: '$current_name' -> '$display_path'"
    @tmux@ rename-window -t "$SESSION:$window_index" "$display_path"
  else
    echo "  Window $window_index: '$current_name' (already correct)"
  fi
done

echo "Done!"

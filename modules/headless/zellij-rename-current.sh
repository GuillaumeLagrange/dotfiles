set -euo pipefail

# Rename the focused zellij tab based on git repo or current directory.

display_name=$(mux-name "$PWD")
zellij action rename-tab "$display_name"

{ pkgs }:
pkgs.writeShellScriptBin "ssh_charybdis.sh" ''
  # Kill existing charybdis window
  ${pkgs.procps}/bin/pgrep -f "Charybdis $1" | xargs -r kill;

  ${pkgs.alacritty}/bin/alacritty --title "Charybdis $1" -e \
  zsh -c "ssh -q -t charybdis 'exec env LANG=C.UTF-8 tmux new-session -A -s $1'";
''

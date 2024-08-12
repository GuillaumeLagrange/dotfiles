{ pkgs }:
pkgs.writeShellScriptBin "lock.sh" ''
  # Suspend notification display
  ${pkgs.procps}/bin/pkill -u "$USER" -USR1 dunst

  ${pkgs.playerctl}/bin/playerctl pause

  # Lock computer
  ${pkgs.swaylock}/bin/swaylock -c 202020 -n

  # Resume notification display
  ${pkgs.procps}/bin/pkill -u "$USER" -USR2 dunst
''

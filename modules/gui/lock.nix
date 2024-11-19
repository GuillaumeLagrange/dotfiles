{ pkgs }:
pkgs.writeShellScriptBin "lock.sh" ''
  # Suspend notification display
  ${pkgs.procps}/bin/pkill -u "$USER" -USR1 dunst

  # Ignore spotify because it's most of going to be playing on another player
  ${pkgs.playerctl}/bin/playerctl -i spotify pause

  # Lock computer
  ${pkgs.swaylock}/bin/swaylock -c 202020 -n

  # Resume notification display
  ${pkgs.procps}/bin/pkill -u "$USER" -USR2 dunst
''

{
  pkgs,
  lib,
  config,
  ...
}:
let
  monster_name = "Cerberus";
in
pkgs.writeShellScriptBin "ssh_monster.sh" ''
  # Kill existing ${monster_name} window
  ${pkgs.procps}/bin/pgrep -f "${monster_name} $1" | xargs -r kill;

  ${config.term} --title "${monster_name} $1" -e \
  zsh -i -c "ssh -q -t ${lib.toLower monster_name} 'exec env LANG=C.UTF-8 tmux new-session -A -s $1'";
''

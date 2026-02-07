{
  pkgs,
  pkgs-unstable,
  lib,
  config,
  ...
}:
let
  lockScript = pkgs.writeShellScriptBin "lock.sh" ''
    # Suspend notification display
    ${pkgs.procps}/bin/pkill -u "$USER" -USR1 dunst

    # Ignore spotify because it's most of going to be playing on another player
    ${pkgs.playerctl}/bin/playerctl -i spotify pause

    # Lock computer
    ${pkgs.hyprlock}/bin/hyprlock

    # Resume notification display
    ${pkgs.procps}/bin/pkill -u "$USER" -USR2 dunst
  '';
in
{
  config = {
    programs.hyprlock = {
      enable = true;
      settings = {
        auth = {
          "fingerprint:enabled" = true;
        };
      };
    };

    home.packages = [
      lockScript
    ];

  };

  options.lock = lib.mkOption {
    type = lib.types.path;
    default = "${lockScript}/bin/lock.sh";
    description = "Path to the lock script";
  };
}

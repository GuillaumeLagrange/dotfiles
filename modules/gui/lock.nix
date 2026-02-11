{
  pkgs,
  pkgs-unstable,
  lib,
  config,
  ...
}:
let
  lockScript = pkgs.writeShellScriptBin "lock.sh" ''
    # Lock computer
    noctalia-shell ipc call lockScreen lock
    sleep 1
  '';
in
{
  config = {
    home.packages = [
      lockScript

      # Very ugly, but supports fprintd, needs to be enabled manually via
      # systemctl --user enable --now hyprpolkitagent.service
      # TODO: Patch soteria and get rid of this
      pkgs.hyprpolkitagent

    ];
  };

  options.lock = lib.mkOption {
    type = lib.types.path;
    default = "${lockScript}/bin/lock.sh";
    description = "Path to the lock script";
  };
}

{
  pkgs,
  lib,
  config,
  ...
}:
{
  options = {
    codspeed.enable = lib.mkEnableOption "codspeed specific tools";
  };

  config = lib.mkIf config.codspeed.enable {
    home.shellAliases = {
      cdc = "cd ~/codspeed";
    };
  };
}

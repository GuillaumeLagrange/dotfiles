{
  pkgs,
  lib,
  config,
  ...
}:
let
  codspeed_root = "${config.home.homeDirectory}/codspeed";
in
{
  options = {
    codspeed.enable = lib.mkEnableOption "codspeed specific tools";
  };

  config = lib.mkIf config.codspeed.enable {
    programs.zsh.initExtra = ''
      # Easy navigation in the codspeed repositories
      cdc() {
        cd "${codspeed_root}/$@"
      }
      compdef '_files -W "${codspeed_root}" -/' cdc
    '';
  };
}

{
  pkgs,
  lib,
  config,
  firefox-pkg,
  ...
}:
let
  perso-profile-name = "perso";
in
{
  options = {
    firefox.enable = lib.mkEnableOption "firefox with personal and work configurations";
  };

  config = lib.mkIf config.firefox.enable {
    programs.firefox = {
      enable = true;
      package = pkgs.firefox-nightly-bin;
      # profiles = {
      #   perso = {
      #     id = 0;
      #     name = perso-profile-name;
      #     isDefault = true;
      #   };
      # };
    };
  };
}

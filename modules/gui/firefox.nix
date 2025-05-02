{
  pkgs,
  lib,
  config,
  ...
}:
{
  options = {
    firefox.enable = lib.mkEnableOption "firefox with personal and work configurations";
  };

  config = lib.mkIf config.firefox.enable {
    programs.firefox = {
      enable = true;
      package = pkgs.firefox-nightly-bin;
    };
  };
}

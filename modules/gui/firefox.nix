{
  pkgs,
  lib,
  config,
  ...
}:
let
  perso-profile-name = "perso";
  stockly-profile-name = "stockly";
in
{
  options = {
    firefox.enable = lib.mkEnableOption "firefox with personal and work configurations";
  };

  config = lib.mkIf config.firefox.enable {
    programs.firefox = {
      enable = true;
      profiles = {
        perso = {
          id = 0;
          name = perso-profile-name;
          isDefault = true;
        };
        stockly = {
          id = 1;
          name = stockly-profile-name;
          isDefault = false;
        };
      };
    };

    xdg.desktopEntries = {
      firefox-perso = {
        name = "Firefox ${perso-profile-name}";
        genericName = "Web Browser";
        exec = "firefox -p ${perso-profile-name}";
        terminal = false;
        categories = [
          "Application"
          "Network"
          "WebBrowser"
        ];
        icon = "firefox";
        mimeType = [
          "text/html"
          "text/xml"
          "application/pdf"
        ];
      };
      firefox-stockly = {
        name = "Firefox ${stockly-profile-name}";
        genericName = "Web Browser";
        exec = "firefox -p ${stockly-profile-name}";
        terminal = false;
        icon = "firefox";
        categories = [
          "Application"
          "Network"
          "WebBrowser"
        ];
      };
    };
  };
}

{
  flake.modules.homeManager.codspeed-linux =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    let
      codspeed_root = "${config.home.homeDirectory}/codspeed";
      vgbasedir = "${codspeed_root}/valgrind-codspeed";
    in
    {
      config = lib.mkIf config.codspeed.enable {
        xdg.desktopEntries = {
          mongodb-compass = {
            name = "MongoDB Compass";
            comment = "The MongoDB GUI";
            genericName = "MongoDB Compass";
            exec = "mongodb-compass --password-store=\"gnome-libsecret\" --ignore-additional-command-line-flags";
            icon = "mongodb-compass";
            categories = [
              "GNOME"
              "GTK"
              "Utility"
            ];
            mimeType = [
              "x-scheme-handler/mongodb"
              "x-scheme-handler/mongodb+srv"
            ];
            startupNotify = true;
          };
        };

        home.packages = with pkgs; [
          mongodb-compass
          mongodb-tools
          kdePackages.kcachegrind

          (writeShellScriptBin "valgrind" ''
            VALGRIND_LIB="${vgbasedir}/.in_place" \
            VALGRIND_LIB_INNER="${vgbasedir}/.in_place" \
            RUSTUP_FORCE_ARG0=cargo \
            exec "${vgbasedir}/coregrind/valgrind" "$@"
          '')
        ];
      };
    };
}

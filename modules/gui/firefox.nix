{
  flake.modules.homeManager.firefox =
    { pkgs, lib, config, ... }:
    {
      options.firefox = {
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.unstable.firefox;
        };

        main = lib.mkOption {
          type = lib.types.str;
          default = "${config.firefox.package}/bin/firefox";
        };

        alt = lib.mkOption {
          type = lib.types.str;
          default = "${config.firefox.package}/bin/firefox --new-instance";
        };
      };

      config = {
        programs.firefox = {
          enable = true;
          package = config.firefox.package;
        };
      };
    };
}

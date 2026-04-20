{
  flake.modules.homeManager.browsers =
    { pkgs, lib, ... }:
    {
      options.browsers = {
        chromium = lib.mkOption {
          type = lib.types.str;
          default = "${pkgs.chromium}/bin/chromium";
        };
      };
    };
}

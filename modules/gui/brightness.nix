{
  flake.modules.homeManager.brightness =
    { pkgs, lib, ... }:
    let
      backlightStep = "10";
    in
    {
      options.brightness = {
        up = lib.mkOption {
          type = lib.types.str;
          default = "exec ${pkgs.brightnessctl}/bin/brightnessctl set ${backlightStep}%+";
        };

        down = lib.mkOption {
          type = lib.types.str;
          default = "exec ${pkgs.brightnessctl}/bin/brightnessctl set ${backlightStep}%- -n 1";
        };

        max = lib.mkOption {
          type = lib.types.str;
          default = "exec ${pkgs.brightnessctl}/bin/brightnessctl set 100%";
        };

        min = lib.mkOption {
          type = lib.types.str;
          default = "exec ${pkgs.brightnessctl}/bin/brightnessctl set 1";
        };
      };
    };
}

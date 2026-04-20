{
  flake.modules.homeManager.monitors =
    { lib, ... }:
    let
      monitorOptions =
        {
          defaultName,
          defaultResolution,
          defaultRefreshRate,
          defaultX,
          defaultY,
        }:
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              default = defaultName;
            };
            resolution = lib.mkOption {
              type = lib.types.str;
              default = defaultResolution;
            };
            refreshRate = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = defaultRefreshRate;
            };
            position = {
              x = lib.mkOption {
                type = lib.types.int;
                default = defaultX;
              };
              y = lib.mkOption {
                type = lib.types.int;
                default = defaultY;
              };
            };
          };
        };
    in
    {
      options.monitors = {
        laptop = lib.mkOption {
          type = monitorOptions {
            defaultName = "eDP-1";
            defaultResolution = "1920x1200";
            defaultRefreshRate = null;
            defaultX = 0;
            defaultY = 1440;
          };
          default = { };
        };

        mainHome = lib.mkOption {
          type = monitorOptions {
            defaultName = "Shenzhen KTC Technology Group OLED G27P6 Unknown";
            defaultResolution = "2560x1440";
            defaultRefreshRate = 60;
            defaultX = 1920;
            defaultY = 1440;
          };
          default = { };
        };

        secondaryHome = lib.mkOption {
          type = monitorOptions {
            defaultName = "Dell Inc. DELL S2421HS 45WFW83";
            defaultResolution = "1920x1080";
            defaultRefreshRate = null;
            defaultX = 4480;
            defaultY = 1440;
          };
          default = { };
        };

        mainOffice = lib.mkOption {
          type = monitorOptions {
            defaultName = "Dell Inc. DELL P2423D FL44W14";
            defaultResolution = "2560x1440";
            defaultRefreshRate = 75;
            defaultX = 1920;
            defaultY = 1440;
          };
          default = { };
        };
      };
    };
}

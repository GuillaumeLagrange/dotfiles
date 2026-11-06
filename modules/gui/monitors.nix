{
  flake.modules.homeManager.monitors =
    { config, lib, ... }:
    let
      logicalWidth =
        monitor:
        let
          width = lib.toInt (builtins.head (lib.splitString "x" monitor.resolution));
          scale = if monitor.scale == null then 1.0 else monitor.scale;
        in
        builtins.floor (width / scale + 0.5);
      laptopWidth = logicalWidth config.monitors.laptop;

      monitorOptions =
        {
          defaultName,
          defaultResolution,
          defaultRefreshRate,
          defaultX,
          defaultY,
          defaultSideStruts ? null,
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
            scale = lib.mkOption {
              type = lib.types.nullOr lib.types.float;
              default = null;
            };
            # niri struts on this output's left and right edges, added to the gaps there.
            sideStruts = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = defaultSideStruts;
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
            defaultX = laptopWidth;
            defaultY = 1440;
            # Its always-on pixel orbiting pushes the 2px focus ring off the panel's side edges.
            defaultSideStruts = 4;
          };
          default = { };
        };

        secondaryHome = lib.mkOption {
          type = monitorOptions {
            defaultName = "Dell Inc. DELL S2421HS 45WFW83";
            defaultResolution = "1920x1080";
            defaultRefreshRate = null;
            defaultX = laptopWidth + logicalWidth config.monitors.mainHome;
            defaultY = 1440;
          };
          default = { };
        };

        mainOffice = lib.mkOption {
          type = monitorOptions {
            defaultName = "Dell Inc. DELL P2423D FN44W14";
            defaultResolution = "2560x1440";
            defaultRefreshRate = 75;
            defaultX = laptopWidth;
            defaultY = 1440;
          };
          default = { };
        };
      };
    };
}

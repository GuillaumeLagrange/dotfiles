{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (lib) types mkOption;
  cfg = config.easyeffects.autoload;
  side = file: lib.head (lib.attrNames (lib.importJSON file));
  flat = "Flat";
  kwriteconfig = "${pkgs.kdePackages.kconfig}/bin/kwriteconfig6";
  flatPreset = s: {
    "easyeffects/${s}/${flat}.json".text = builtins.toJSON {
      ${s} = {
        blocklist = [ ];
        plugins_order = [ ];
      };
    };
  };
in
{
  _class = "homeManager";

  options.easyeffects.autoload = mkOption {
    description = "EasyEffects presets, by name, and the device each one loads on.";
    default = { };
    type = types.attrsOf (
      types.submodule (
        { config, ... }:
        {
          options = {
            device = mkOption {
              type = types.str;
              description = "PipeWire node name.";
            };
            profile = mkOption {
              type = types.str;
              description = "Route of the device, as EasyEffects shows it.";
            };
            description = mkOption {
              type = types.str;
              default = config.device;
              description = "Device name shown in EasyEffects' autoload list.";
            };
            preset = mkOption {
              type = types.path;
              description = "Preset JSON; its top block (input/output) is the side it applies to.";
            };
          };
        }
      )
    );
  };

  config = lib.mkIf (cfg != { }) {
    services.easyeffects.enable = true;

    xdg.dataFile = lib.mkMerge (
      [
        (flatPreset "input")
        (flatPreset "output")
      ]
      ++ lib.mapAttrsToList (name: a: {
        "easyeffects/${side a.preset}/${name}.json".source = a.preset;
        "easyeffects/autoload/${side a.preset}/${a.device}:${a.profile}.json".text = builtins.toJSON {
          inherit (a) device;
          device-description = a.description;
          device-profile = a.profile;
          preset-name = name;
        };
      }) cfg
    );

    home.activation.easyeffectsFallback = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      lib.concatMapStrings
        (s: ''
          run ${kwriteconfig} --file easyeffects/db/easyeffectsrc --group Window \
            --key ${s}AutoloadingUsesFallback true
          run ${kwriteconfig} --file easyeffects/db/easyeffectsrc --group Window \
            --key ${s}AutoloadingFallbackPreset ${flat}
        '')
        [
          "input"
          "output"
        ]
    );
  };
}

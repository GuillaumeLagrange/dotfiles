{
  inputs,
  lib,
  config,
  ...
}:
{
  options.configurations.home = lib.mkOption {
    type = lib.types.lazyAttrsOf (
      lib.types.submodule {
        options = {
          pkgs = lib.mkOption { type = lib.types.unspecified; };
          modules = lib.mkOption {
            type = lib.types.listOf lib.types.unspecified;
            default = [ ];
          };
          extraSpecialArgs = lib.mkOption {
            type = lib.types.attrsOf lib.types.unspecified;
            default = { };
          };
        };
      }
    );
    default = { };
  };

  config.flake.homeConfigurations = lib.flip lib.mapAttrs config.configurations.home (
    _name: entry:
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit (entry) pkgs modules;
      extraSpecialArgs = entry.extraSpecialArgs // {
        hmModules = config.flake.modules.homeManager or { };
      };
    }
  );
}

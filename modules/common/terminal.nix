{
  flake.modules.homeManager.terminal =
    { pkgs, lib, ... }:
    {
      options = {
        term = lib.mkOption {
          type = lib.types.str;
          default = "${pkgs.kitty}/bin/kitty";
        };

        termDesktopEntry = lib.mkOption {
          type = lib.types.str;
          default = builtins.head (builtins.attrNames (builtins.readDir "${pkgs.kitty}/share/applications"));
        };
      };
    };
}

{
  flake.modules.homeManager.terminal =
    { pkgs, lib, ... }:
    {
      options = {
        term = lib.mkOption {
          type = lib.types.str;
          default = "${pkgs.ghostty}/bin/ghostty";
        };

        termDesktopEntry = lib.mkOption {
          type = lib.types.str;
          default = builtins.head (builtins.attrNames (builtins.readDir "${pkgs.ghostty}/share/applications"));
        };
      };
    };
}

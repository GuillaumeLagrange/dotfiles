{
  flake.modules.homeManager.stylix-home =
    { config, lib, ... }:
    {
      config = lib.mkIf config.stylix.enable {
        stylix.targets = {
          neovim.enable = false;
          hyprland.enable = false;
          wofi.enable = false;
          firefox.enable = false;
          vscode.enable = false;
        };
      };
    };
}

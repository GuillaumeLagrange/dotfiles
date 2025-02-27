# Home-manager specific stylix configuration
{ pkgs, ... }:
{
  stylix.targets = {
    neovim.enable = false;
    wofi.enable = false;
    # Disabling all this enables us to manage the wallpapers ourselves
    sway.enable = false;
    wpaperd.enable = false;
    hyprpaper.enable = false;
    hyprland.enable = false;
    vscode.enable = false;
  };
}

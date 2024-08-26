# Home-manager specific stylix configuration
{ pkgs, ... }:
{
  stylix.targets = {
    neovim.enable = false;
    wofi.enable = false;
  };
}

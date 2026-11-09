{ pkgs, lib, ... }:
{
  _class = "homeManager";

  stylix.enable = true;
  stylix.polarity = "dark";
  stylix.base16Scheme = "${pkgs.base16-schemes}/share/themes/gruvbox-material-dark-medium.yaml";

  stylix.fonts = {
    sizes = {
      applications = 9;
      terminal = 10;
    };
    monospace = {
      name = "Hack Nerd Font";
      package = pkgs.nerd-fonts.hack;
    };
    sansSerif = {
      name = "Inter";
      package = pkgs.inter;
    };
    serif = {
      name = "Inter";
      package = pkgs.inter;
    };
    emoji = {
      name = "Noto Color Emoji";
      package = pkgs.noto-fonts-color-emoji;
    };
  };
  stylix.opacity.terminal = 0.95;

  stylix.targets = {
    neovim.enable = false;
    wofi.enable = false;
    firefox.enable = false;
    vscode.enable = false;

    # Off without a screen; the desktop group turns them on.
    gnome.enable = lib.mkDefault false;
    gtk.enable = lib.mkDefault false;
    gnome-text-editor.enable = lib.mkDefault false;
    nixos-icons.enable = lib.mkDefault false;
  };
}

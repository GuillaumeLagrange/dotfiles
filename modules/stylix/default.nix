{ pkgs, ... }:
{
  stylix.enable = true;
  # stylix.image = "${config.home.homeDirectory}/documents/wallpapers/d8clif9-4826a808-7242-4146-8993-0b92125bedb8.jpg";
  stylix.image = ./gruvbox-mountain-village.png;
  stylix.polarity = "dark";
  stylix.base16Scheme = "${pkgs.base16-schemes}/share/themes/gruvbox-material-dark-medium.yaml";
  stylix.targets = {
    neovim.enable = false;
    wofi.enable = false;
  };
  stylix.fonts = {
    monospace = {
      name = "Hack Nerd Font";
      package = pkgs.nerdfonts.override { fonts = [ "Hack" ]; };
    };
    emoji = {
      package = pkgs.noto-fonts-emoji;
    };
  };
  stylix.fonts = {
    sizes = {
      applications = 9;
      terminal = 10;
    };
  };
  stylix.opacity.terminal = 0.95;
}

# Stylix base configuration
{
  pkgs,
  config,
  lib,
  ...
}:
{
  config = lib.mkIf config.stylix.enable {
    stylix.polarity = "dark";
    stylix.base16Scheme = "${pkgs.base16-schemes}/share/themes/gruvbox-material-dark-medium.yaml";

    stylix.fonts = {
      sizes = {
        applications = 9;
        terminal = 10;
      };
    };
    stylix.opacity.terminal = 0.95;
    stylix.fonts = {
      monospace = {
        name = "Hack Nerd Font";
        package = pkgs.nerd-fonts.hack;
      };
      emoji = {
        name = "Noto Color Emoji";
        package = pkgs.noto-fonts-color-emoji;
      };
    };
  };
}

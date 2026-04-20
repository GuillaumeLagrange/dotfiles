{ inputs, ... }:
{
  flake.modules.nixos.stylix = {
    imports = [ inputs.stylix.nixosModules.stylix ];
  };

  flake.modules.homeManager.stylix =
    { pkgs, ... }:
    {
      imports = [ inputs.stylix.homeModules.stylix ];

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
        emoji = {
          name = "Noto Color Emoji";
          package = pkgs.noto-fonts-color-emoji;
        };
      };
      stylix.opacity.terminal = 0.95;

      stylix.targets = {
        neovim.enable = false;
        hyprland.enable = false;
        wofi.enable = false;
        firefox.enable = false;
        vscode.enable = false;
      };
    };
}

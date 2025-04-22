# Home-manager specific stylix configuration
{
  pkgs,
  config,
  lib,
  ...
}:
{
  config = lib.mkIf config.stylix.enable {
    stylix.targets = {
      neovim.enable = false;
      wofi.enable = false;
      firefox.enable = false;
      vscode.enable = false;
    };
  };
}

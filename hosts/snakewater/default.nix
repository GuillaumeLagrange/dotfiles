# snakewater: personal desktop.
{ self, inputs, ... }:
{
  flake.nixosConfigurations.snakewater = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.modules.nixos.core
      self.modules.nixos.desktop
      self.modules.nixos.encrypted-disk
      self.modules.nixos.secure-boot
      ./hardware.nix
      ./configuration.nix
      {
        greeter.wallpaper = ./greeter-wallpaper.jpg;
        home-manager.users.guillaume.imports = [
          self.modules.homeManager.personal-desktop
          ./easyeffects.nix
        ];
      }
    ];
  };
}

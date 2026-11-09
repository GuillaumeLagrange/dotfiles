# badlands: work laptop.
{ self, inputs, ... }:
{
  flake.nixosConfigurations.badlands = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.modules.nixos.core
      self.modules.nixos.desktop
      self.modules.nixos.laptop
      self.modules.nixos.secure-boot
      self.modules.nixos.work
      ./hardware.nix
      ./configuration.nix
      { home-manager.users.guillaume.imports = [ self.modules.homeManager.work-laptop ]; }
    ];
  };
}

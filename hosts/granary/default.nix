# granary: work laptop.
{ self, inputs, ... }:
{
  flake.nixosConfigurations.granary = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.modules.nixos.core
      self.modules.nixos.desktop
      self.modules.nixos.laptop
      self.modules.nixos.encrypted-disk
      self.modules.nixos.secure-boot
      self.modules.nixos.work
      inputs.nixos-hardware.nixosModules.framework-intel-core-ultra-series3
      inputs.intel-lpmd.nixosModules.default
      ./hardware.nix
      ./configuration.nix
      ./caffeine.nix
      ./keylightd.nix
      ./ttm-reclaim.nix
      {
        home-manager.users.guillaume.imports = [
          self.modules.homeManager.work-laptop
          ./easyeffects.nix
        ];
      }
    ];
  };
}

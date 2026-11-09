# gullywash: home server.
{ self, inputs, ... }:
{
  flake.nixosConfigurations.gullywash = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.modules.nixos.core
      ./hardware.nix
      ./zfs.nix
      ./configuration.nix
      {
        home-manager.users.guillaume.imports = [
          self.modules.homeManager.server
          (self.lib.zellijAccent "base0D")
        ];
      }
    ];
  };
}

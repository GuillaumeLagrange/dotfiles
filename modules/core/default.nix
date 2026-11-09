# core: imported by every NixOS host and every home.
{ self, inputs, ... }:
{
  # The machine as nix and the user see it: nix settings, the overlay, the
  # `guillaume` account and the home-manager wiring that gives it a home.
  flake.modules.nixos.core = {
    imports = [
      inputs.home-manager.nixosModules.home-manager
      inputs.nix-index-database.nixosModules.nix-index
      ./nixos.nix
    ];

    nixpkgs.overlays = [ self.overlays.default ];
  };

  # What any home is before it gets a role: identity, xdg dirs, fonts, theme. It
  # assumes no screen; the desktop group adds one.
  flake.modules.homeManager.core = {
    imports = [
      inputs.stylix.homeModules.stylix
      ./home.nix
      ./theme.nix
    ];
  };
}

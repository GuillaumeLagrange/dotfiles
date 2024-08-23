{ inputs, ... }:

inputs.nixpkgs.lib.nixosSystem rec {
  system = "x86_64-linux";
  specialArgs = {
    pkgs-datagrip = import inputs.nixpkgs-datagrip { inherit system; };
  };
  modules = [
    inputs.lanzaboote.nixosModules.lanzaboote
    # inputs.home-manager.nixosModules.home-manager
    inputs.stylix.nixosModules.stylix
    ./configuration.nix
    # ../../modules/home-manager.nix
  ];
}

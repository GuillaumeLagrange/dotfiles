{ inputs, ... }:

inputs.nixpkgs.lib.nixosSystem rec {
  system = "x86_64-linux";
  modules = [
    inputs.lanzaboote.nixosModules.lanzaboote
    inputs.home-manager.nixosModules.home-manager
    inputs.stylix.nixosModules.stylix
    ../../modules/stylix/common.nix
    ./configuration.nix
    inputs.nix-index-database.nixosModules.nix-index
    { programs.nix-index-database.comma.enable = true; }
  ];
}

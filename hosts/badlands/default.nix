{
  inputs,
  pkgs-unstable,
  ...
}:

inputs.nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  specialArgs = { inherit pkgs-unstable; };
  modules = [
    (import ../nixos-common.nix { inherit inputs; })
    (import ../../modules/nixos/secure-boot.nix { lanzaboote = inputs.lanzaboote; })
    (import ../../modules/stylix/nixos.nix { inherit inputs; })
    ./configuration.nix
  ];
}

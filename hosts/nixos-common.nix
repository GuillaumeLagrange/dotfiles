{ inputs }:

{
  imports = [
    ./common.nix
    inputs.nix-index-database.nixosModules.nix-index
    (import ../modules/nixos/home-manager.nix { inherit inputs; })
  ];
}

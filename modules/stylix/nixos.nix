{ inputs }:

{
  imports = [
    inputs.stylix.nixosModules.stylix
    ./common.nix
  ];
}

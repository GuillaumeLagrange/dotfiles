{ inputs }:

{
  imports = [
    inputs.stylix.homeModules.stylix
    ./common.nix
    ./home-manager.nix
  ];
}

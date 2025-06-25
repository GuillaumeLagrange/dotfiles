{ inputs, sshPublicKey, ... }:

inputs.nixpkgs.lib.nixosSystem rec {
  system = "x86_64-linux";
  specialArgs = {
    pkgs-datagrip = import inputs.nixpkgs-datagrip { inherit system; };
    inherit sshPublicKey;
  };
  modules = [
    ./configuration.nix
    inputs.nix-index-database.nixosModules.nix-index
    { programs.nix-index-database.comma.enable = true; }
  ];
}

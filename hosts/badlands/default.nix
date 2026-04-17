{
  inputs,
  pkgs-unstable,
  hm,
  ...
}:

inputs.nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  modules = [
    (import ../../modules/secure_boot.nix { lanzaboote = inputs.lanzaboote; })
    inputs.stylix.nixosModules.stylix
    ../../modules/stylix/common.nix
    ./configuration.nix
    inputs.nix-index-database.nixosModules.nix-index
    { programs.nix-index-database.comma.enable = true; }
    hm
    {
      _module.args.pkgs-unstable = pkgs-unstable;
      home-manager.users.guillaume.imports = [ ../../modules/stylix/common.nix ];
    }
  ];
}

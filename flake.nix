{
  description = "Home Manager configuration of guillaume";

  inputs = {
    # Specify the source of Home Manager and Nixpkgs.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      nix-index-database,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      homeConfigurations."guillaume" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./home.nix
          nix-index-database.hmModules.nix-index
        ];
      };

      homeConfigurations."glagrange" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./arch.nix
          ./home.nix
          nix-index-database.hmModules.nix-index
        ];
      };
    };
}

{
  description = "Home Manager configuration of guillaume";

  inputs = {
    # Specify the source of Home Manager and Nixpkgs.
    datagrip-nixpkgs.url = "github:nixos/nixpkgs/3847a2a8595bba68214ac4b7e3da3fc00776989";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    stylix = {
      url = "github:danth/stylix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      nix-index-database,
      datagrip-nixpkgs,
      stylix,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      datagrip-pkgs = import datagrip-nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      homeConfigurations."guillaume" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./home.nix
          stylix.homeManagerModules.stylix
          nix-index-database.hmModules.nix-index
        ];
        extraSpecialArgs = {
          inherit datagrip-pkgs;
        };
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

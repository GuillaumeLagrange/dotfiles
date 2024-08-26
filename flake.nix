{
  description = "Home Manager configuration of guillaume";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v0.4.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    stylix = {
      url = "github:danth/stylix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs-datagrip.url = "github:nixos/nixpkgs/3847a2a8595bba68214ac4b7e3da3fc00776989";
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      nixpkgs-datagrip,
      stylix,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          segger-jlink.acceptLicense = true;
          permittedInsecurePackages = [ "segger-jlink-qt4-796s" ];
        };
      };
      pkgs-datagrip = import nixpkgs-datagrip {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      homeConfigurations."guillaume" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          stylix.homeManagerModules.stylix
          ./modules/stylix/common.nix
          ./modules/home-manager.nix
        ];
        extraSpecialArgs = {
          inherit pkgs-datagrip;
        };
      };

      nixosConfigurations = {
        badlands = import ./hosts/badlands/default.nix { inherit inputs; };
      };

    };
}

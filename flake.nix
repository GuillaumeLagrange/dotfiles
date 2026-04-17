{
  description = "Home Manager configuration of guillaume";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v0.4.3";
      # Fails to build otherwise for now after 25.11 switch, retry later
      # inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    stylix = {
      url = "github:nix-community/stylix/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { withSystem, ... }:
      {
        systems = [
          "x86_64-linux"
          "aarch64-darwin"
        ];

        perSystem =
          { system, ... }:
          let
            mkPkgs = src: import src { inherit system; config.allowUnfree = true; };
          in
          {
            _module.args = {
              pkgs = mkPkgs inputs.nixpkgs;
              pkgs-unstable = mkPkgs inputs.nixpkgs-unstable;
            };
          };

        flake =
          let
            sshPublicKey = inputs.nixpkgs.lib.trim (builtins.readFile ./modules/home-manager/headless/guiom_ssh.pub);

            mkHome =
              { pkgs, pkgs-unstable }:
              extraModules:
              inputs.home-manager.lib.homeManagerConfiguration {
                inherit pkgs;
                extraSpecialArgs = { inherit pkgs-unstable; };
                modules = [
                  (import ./modules/stylix { inherit inputs; })
                  ./modules/home-manager
                ] ++ extraModules;
              };

            linux = withSystem "x86_64-linux" (
              { pkgs, pkgs-unstable, ... }:
              {
                homeConfigurations."guillaume" = mkHome { inherit pkgs pkgs-unstable; } [ ];

                nixosConfigurations = {
                  badlands = import ./hosts/badlands { inherit inputs pkgs-unstable; };
                  gullywash = import ./hosts/gullywash { inherit inputs pkgs-unstable sshPublicKey; };

                  guiom-nixos-installation = inputs.nixpkgs.lib.nixosSystem {
                    system = "x86_64-linux";
                    modules = [ (import ./modules/nixos/installation-media.nix { inherit inputs sshPublicKey; }) ];
                  };
                };
              }
            );

            darwin = withSystem "aarch64-darwin" (
              { pkgs, pkgs-unstable, ... }:
              {
                homeConfigurations."codspeed" = mkHome { inherit pkgs pkgs-unstable; } [ ./hosts/mac-mini/home.nix ];
              }
            );
          in
          {
            homeConfigurations = linux.homeConfigurations // darwin.homeConfigurations;
            inherit (linux) nixosConfigurations;
          };
      }
    );
}

{
  description = "Guillaume's machines and home-manager configs";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    quickshell = {
      url = "github:quickshell-mirror/quickshell";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    stylix = {
      url = "github:nix-community/stylix/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    intel-lpmd = {
      url = "github:dmfrpro/intel-lpmd-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # Every file that defines a module or an output is listed here, so a name leads to
  # its file: `self.modules.<class>.<name>` comes from modules/<name> or homes/<name>.nix.
  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      imports = [
        inputs.flake-parts.flakeModules.modules
        # Lets several files define homeConfigurations.
        inputs.home-manager.flakeModules.home-manager

        # overlays.default and packages
        ./pkgs
        # devShells.default: the Justfile's and the hooks' tools
        ./devshell.nix

        # Groups: modules.nixos.<name> and modules.homeManager.<name>
        ./modules/core
        ./modules/shell
        ./modules/desktop
        ./modules/work
        ./modules/laptop.nix
        ./modules/encrypted-disk.nix
        ./modules/secure-boot.nix
        ./modules/stall-tracing

        # Homes: modules.homeManager.<name>, and homeConfigurations
        ./homes/work-laptop.nix
        ./homes/personal-desktop.nix
        ./homes/server.nix
        ./homes/codspeed-mac.nix
        ./homes/cloud.nix

        # Hosts: nixosConfigurations.<name>
        ./hosts/badlands
        ./hosts/granary
        ./hosts/snakewater
        ./hosts/gullywash
        ./hosts/installer.nix
      ];
    };
}

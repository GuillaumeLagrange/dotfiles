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
      { config, withSystem, ... }:
      {
        systems = [
          "x86_64-linux"
          "aarch64-darwin"
        ];

        perSystem =
          { system, ... }:
          let
            pkgs = import inputs.nixpkgs {
              inherit system;
              config.allowUnfree = true;
            };
            pkgs-unstable = import inputs.nixpkgs-unstable {
              inherit system;
              config.allowUnfree = true;
            };
          in
          {
            _module.args = {
              inherit pkgs pkgs-unstable;
            };
          };

        flake =
          let
            sshPublicKey = inputs.nixpkgs.lib.trim (builtins.readFile ./modules/headless/guiom_ssh.pub);

            linux = withSystem "x86_64-linux" (
              { pkgs, pkgs-unstable, ... }:
              {
                homeConfigurations."guillaume" = inputs.home-manager.lib.homeManagerConfiguration {
                  inherit pkgs;
                  modules = [
                    inputs.stylix.homeModules.stylix
                    ./modules/stylix/common.nix
                    ./modules/home-manager.nix
                  ];
                  extraSpecialArgs = { inherit pkgs-unstable; };
                };

                nixosConfigurations = {
                  badlands = import ./hosts/badlands/default.nix {
                    inherit inputs pkgs-unstable;
                    inherit (config.flake.nixosModules) hm;
                  };
                  gullywash = import ./hosts/gullywash/default.nix {
                    inherit inputs pkgs-unstable sshPublicKey;
                    inherit (config.flake.nixosModules) hm;
                  };

                  guiom-nixos-installation = inputs.nixpkgs.lib.nixosSystem {
                    system = "x86_64-linux";
                    modules = [
                      (import ./modules/nixos-installation-media.nix { inherit inputs sshPublicKey; })
                    ];
                  };
                };
              }
            );

            darwin = withSystem "aarch64-darwin" (
              { pkgs, pkgs-unstable, ... }:
              {
                # IN PROGRESS: mac-mini configuration of my home-manager flake
                homeConfigurations."codspeed" = inputs.home-manager.lib.homeManagerConfiguration {
                  inherit pkgs;
                  modules = [
                    {
                      home.username = "codspeed";
                      home.homeDirectory = "/Users/codspeed";
                      gui.enable = false;
                      stockly.enable = false;
                      programs.zsh.oh-my-zsh.theme = "gnzh";
                      # GPG agent is forwarded via SSH, prevent local auto-start
                      programs.gpg.settings.no-autostart = true;
                    }
                    inputs.stylix.homeModules.stylix
                    ./modules/home-manager.nix
                  ];
                  extraSpecialArgs = { inherit pkgs-unstable; };
                };
              }
            );
          in
          {
            nixosModules.hm = import ./modules/home-manager-nixos.nix { inherit inputs; };
            homeConfigurations = linux.homeConfigurations // darwin.homeConfigurations;
            inherit (linux) nixosConfigurations;
          };
      }
    );
}

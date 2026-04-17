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

        flake = withSystem "x86_64-linux" (
          linuxCtx:
          withSystem "aarch64-darwin" (
            darwinCtx:
            let
              inherit (linuxCtx) pkgs pkgs-unstable;
              darwinPkgs = darwinCtx.pkgs;
              darwinPkgsUnstable = darwinCtx.pkgs-unstable;
              sshPublicKey = inputs.nixpkgs.lib.trim (builtins.readFile ./modules/headless/guiom_ssh.pub);

              mkHomeManagerModule =
                {
                  extraModules ? [ ],
                  extraConfig ? { },
                }:
                {
                  home-manager.useGlobalPkgs = true;
                  home-manager.useUserPackages = true;
                  home-manager.backupFileExtension = "backup";
                  home-manager.extraSpecialArgs = { inherit pkgs-unstable; };
                  home-manager.users.guillaume = {
                    imports = [
                      inputs.stylix.homeModules.stylix
                      ./modules/home-manager.nix
                    ]
                    ++ extraModules;
                    stylix.overlays.enable = false;
                  }
                  // extraConfig;
                };
            in
            {
              homeConfigurations = {
                "guillaume" = inputs.home-manager.lib.homeManagerConfiguration {
                  inherit pkgs;
                  modules = [
                    inputs.stylix.homeModules.stylix
                    ./modules/stylix/common.nix
                    ./modules/home-manager.nix
                  ];
                  extraSpecialArgs = {
                    inherit pkgs-unstable;
                  };
                };

                # IN PROGRESS: mac-mini configuration of my home-manager flake
                "codspeed" = inputs.home-manager.lib.homeManagerConfiguration {
                  pkgs = darwinPkgs;
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
                  extraSpecialArgs = {
                    pkgs-unstable = darwinPkgsUnstable;
                  };
                };

                "guillaume@gullywash" = inputs.home-manager.lib.homeManagerConfiguration {
                  inherit pkgs;
                  modules = [
                    {
                      gui.enable = false;
                      codspeed.enable = false;
                      programs.zsh.oh-my-zsh.theme = "gnzh";
                    }
                    inputs.stylix.homeModules.stylix
                    ./modules/home-manager.nix
                  ];
                  extraSpecialArgs = {
                    inherit pkgs-unstable;
                  };
                };
              };

              nixosConfigurations = {
                badlands = import ./hosts/badlands/default.nix {
                  inherit inputs mkHomeManagerModule;
                };
                gullywash = import ./hosts/gullywash/default.nix {
                  inherit inputs sshPublicKey mkHomeManagerModule;
                };

                guiom-nixos-installation = inputs.nixpkgs.lib.nixosSystem {
                  system = "x86_64-linux";
                  modules = [
                    "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
                    {
                      isoImage.isoName = "guiom-nixos-installation.iso";

                      nix.settings.experimental-features = [
                        "nix-command"
                        "flakes"
                      ];

                      services.openssh = {
                        enable = true;
                        settings = {
                          PasswordAuthentication = false;
                          PermitRootLogin = "yes";
                        };
                      };
                      systemd.services.sshd.wantedBy = pkgs.lib.mkForce [ "multi-user.target" ];

                      environment.systemPackages = with pkgs; [
                        neovim
                        wpa_supplicant
                      ];

                      users.users.root.openssh.authorizedKeys.keys = [ sshPublicKey ];

                      networking.networkmanager.enable = true;
                      networking.wireless.enable = false;
                    }
                  ];
                };
              };
            }
          )
        );
      }
    );
}

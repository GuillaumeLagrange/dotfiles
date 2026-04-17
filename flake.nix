{
  description = "Home Manager configuration of guillaume";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
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
    {
      home-manager,
      nixpkgs,
      nixpkgs-unstable,
      stylix,
      ...
    }@inputs:
    let
      mkPkgsFor =
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          pkgs-unstable = import nixpkgs-unstable {
            inherit system;
            config.allowUnfree = true;
          };
        in
        {
          inherit pkgs pkgs-unstable;
        };

      linuxPkgs = mkPkgsFor "x86_64-linux";
      darwinPkgs = mkPkgsFor "aarch64-darwin";

      # Keep top-level bindings for existing NixOS configs
      system = "x86_64-linux";
      inherit (linuxPkgs) pkgs pkgs-unstable;

      # Shared SSH key configuration
      sshPublicKey = nixpkgs.lib.trim (builtins.readFile ./modules/headless/guiom_ssh.pub);

      # Helper to wire Home Manager as a NixOS module with shared config
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
              stylix.homeModules.stylix
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
        "guillaume" = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            stylix.homeModules.stylix
            ./modules/stylix/common.nix
            ./modules/home-manager.nix
          ];
          extraSpecialArgs = {
            inherit pkgs-unstable;
          };
        };

        # IN PROGRESS: mac-mini configuration of my home-manager flake
        "codspeed" = home-manager.lib.homeManagerConfiguration {
          pkgs = darwinPkgs.pkgs;
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
            stylix.homeModules.stylix
            ./modules/home-manager.nix
          ];
          extraSpecialArgs = {
            pkgs-unstable = darwinPkgs.pkgs-unstable;
          };
        };

        "guillaume@gullywash" = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            {
              gui.enable = false;
              codspeed.enable = false;
              programs.zsh.oh-my-zsh.theme = "gnzh";
            }
            stylix.homeModules.stylix
            ./modules/home-manager.nix
          ];
          extraSpecialArgs = {
            inherit pkgs-unstable;
          };
        };
      };

      nixosConfigurations = {
        badlands = import ./hosts/badlands/default.nix { inherit inputs mkHomeManagerModule; };
        gullywash = import ./hosts/gullywash/default.nix {
          inherit inputs sshPublicKey mkHomeManagerModule;
        };

        guiom-nixos-installation = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            {
              # Set ISO name
              isoImage.isoName = "guiom-nixos-installation.iso";

              # Enable flakes
              nix.settings.experimental-features = [
                "nix-command"
                "flakes"
              ];

              # Enable SSH daemon and force it to start
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

              # Configure root user with SSH key
              users.users.root.openssh.authorizedKeys.keys = [ sshPublicKey ];

              # Network configuration - enable both wired and wireless
              networking.networkmanager.enable = true;
              networking.wireless.enable = false; # NetworkManager handles wifi
            }
          ];
        };
      };

    };
}

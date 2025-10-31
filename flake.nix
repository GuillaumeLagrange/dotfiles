{
  description = "Home Manager configuration of guillaume";

  nixConfig = {
    extra-substituters = [ "https://vicinae.cachix.org" ];
    extra-trusted-public-keys = [ "vicinae.cachix.org-1:1kDrfienkGHPYbkpNj1mWTr7Fm1+zcenzgTizIcI3oc=" ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v0.4.2";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    stylix = {
      url = "github:nix-community/stylix/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    vicinae = {
      url = "github:vicinaehq/vicinae";
      # No nixpkgs follow to make use of cache
    };
  };

  outputs =
    {
      home-manager,
      nixpkgs,
      nixpkgs-unstable,
      stylix,
      vicinae,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
        };
      };
      pkgs-unstable = import nixpkgs-unstable {
        inherit system;
        config = {
          allowUnfree = true;
        };
      };

      # Shared SSH key configuration
      sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICB1BgyotMSfKqSwUoeMKJcC6d+y468PRjPrcnvMxZBW cardno:29_644_001";
    in
    {
      homeConfigurations = {
        "guillaume" = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            stylix.homeModules.stylix
            vicinae.homeManagerModules.default
            ./modules/stylix/common.nix
            ./modules/home-manager.nix
          ];
          extraSpecialArgs = {
            inherit pkgs-unstable;
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
        badlands = import ./hosts/badlands/default.nix { inherit inputs; };
        gullywash = import ./hosts/gullywash/default.nix { inherit inputs sshPublicKey; };

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

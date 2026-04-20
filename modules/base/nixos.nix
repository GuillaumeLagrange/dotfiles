{ inputs, ... }:
{
  flake.modules.nixos.base =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    {
      imports = [
        inputs.nix-index-database.nixosModules.nix-index
      ];

      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
      };

      nix.extraOptions = ''
        trusted-users = root guillaume
      '';

      programs.nix-ld.enable = true;

      time.timeZone = "Europe/Paris";

      programs.zsh.enable = true;

      users.users.guillaume = {
        isNormalUser = true;
        description = "Guillaume";
        extraGroups = [
          "wheel"
          "docker"
        ];
        shell = pkgs.zsh;
      };

      virtualisation.docker.enable = true;

      environment.systemPackages = with pkgs; [
        wget
        home-manager
      ];

      programs.nix-index-database.comma.enable = true;

      nix.optimise.automatic = true;
      programs.nh = {
        enable = true;
        clean = {
          enable = true;
          dates = "weekly";
          extraArgs = "--keep-since 7d --keep 3";
        };
      };

      nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
      hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

      system.activationScripts.binbash = {
        text = ''
          mkdir -p /bin
          ln -sf ${pkgs.bash}/bin/bash /bin/bash
        '';
      };
    };
}

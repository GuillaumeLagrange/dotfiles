{ self, inputs, ... }:
{
  flake.modules.nixos.installation-media =
    { pkgs, ... }:
    {
      imports = [
        "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
      ];

      image.fileName = "guiom-nixos-installation.iso";

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

      users.users.root.openssh.authorizedKeys.keys = [
        (inputs.nixpkgs.lib.trim (builtins.readFile ../../headless/guiom_ssh.pub))
      ];

      networking.networkmanager.enable = true;
      networking.wireless.enable = false;
    };

  flake.nixosConfigurations.guiom-nixos-installation = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ self.modules.nixos.installation-media ];
  };
}

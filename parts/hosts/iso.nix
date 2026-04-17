{
  inputs,
  withSystem,
  sshPublicKey,
  ...
}:
{
  flake.nixosConfigurations.guiom-nixos-installation = withSystem "x86_64-linux" (
    { pkgs, ... }:
    inputs.nixpkgs.lib.nixosSystem {
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
    }
  );
}

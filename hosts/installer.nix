# The installation ISO: minimal NixOS with flakes, root reachable over SSH.
#   nix build .#nixosConfigurations.guiom-nixos-installation.config.system.build.isoImage
{ inputs, ... }:
{
  flake.nixosConfigurations.guiom-nixos-installation = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
      (
        { pkgs, lib, ... }:
        {
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
          systemd.services.sshd.wantedBy = lib.mkForce [ "multi-user.target" ];

          environment.systemPackages = with pkgs; [
            neovim
            wpa_supplicant
          ];

          users.users.root.openssh.authorizedKeys.keys = [
            (lib.trim (builtins.readFile ./guiom_ssh.pub))
          ];

          networking.networkmanager.enable = true;
        }
      )
    ];
  };
}

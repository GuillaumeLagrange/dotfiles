{
  inputs,
  withSystem,
  mkHomeManagerModule,
  sshPublicKey,
  ...
}:
{
  configurations.nixos.gullywash.module = withSystem "x86_64-linux" (
    { pkgs-unstable, ... }:
    {
      imports = [
        inputs.home-manager.nixosModules.home-manager
        ../../hosts/gullywash/configuration.nix
        inputs.nix-index-database.nixosModules.nix-index
        { programs.nix-index-database.comma.enable = true; }
        (mkHomeManagerModule { inherit pkgs-unstable; } {
          extraConfig = {
            gui.enable = false;
            codspeed.enable = false;
            programs.zsh.oh-my-zsh.theme = "gnzh";
          };
        })
      ];

      _module.args.sshPublicKey = sshPublicKey;
    }
  );
}

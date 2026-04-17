{
  inputs,
  withSystem,
  sshPublicKey,
  config,
  ...
}:
{
  configurations.nixos.gullywash.module = withSystem "x86_64-linux" (
    { pkgs-unstable, ... }:
    {
      imports = [
        config.flake.modules.nixos.home-manager-base
        ../../hosts/gullywash/configuration.nix
        inputs.nix-index-database.nixosModules.nix-index
        { programs.nix-index-database.comma.enable = true; }
      ];

      _module.args.pkgs-unstable = pkgs-unstable;
      _module.args.sshPublicKey = sshPublicKey;

      home-manager.users.guillaume = {
        gui.enable = false;
        codspeed.enable = false;
        programs.zsh.oh-my-zsh.theme = "gnzh";
      };
    }
  );
}

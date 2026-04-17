{ inputs, ... }:
{
  _module.args = {
    sshPublicKey = inputs.nixpkgs.lib.trim (builtins.readFile ../modules/headless/guiom_ssh.pub);

    mkHomeManagerModule =
      { pkgs-unstable }:
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
            ../modules/home-manager.nix
          ]
          ++ extraModules;
          stylix.overlays.enable = false;
        }
        // extraConfig;
      };
  };
}

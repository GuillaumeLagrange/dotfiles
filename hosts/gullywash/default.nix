{ inputs, sshPublicKey, mkHomeManagerModule, ... }:

inputs.nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  specialArgs = {
    inherit sshPublicKey;
  };
  modules = [
    inputs.home-manager.nixosModules.home-manager
    ./configuration.nix
    inputs.nix-index-database.nixosModules.nix-index
    { programs.nix-index-database.comma.enable = true; }
    (mkHomeManagerModule {
      extraConfig = {
        gui.enable = false;
        codspeed.enable = false;
        programs.zsh.oh-my-zsh.theme = "gnzh";
      };
    })
  ];
}

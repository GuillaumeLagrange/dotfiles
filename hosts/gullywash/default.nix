{
  inputs,
  pkgs-unstable,
  sshPublicKey,
  hm,
  ...
}:

inputs.nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  specialArgs = {
    inherit sshPublicKey;
  };
  modules = [
    ./configuration.nix
    inputs.nix-index-database.nixosModules.nix-index
    { programs.nix-index-database.comma.enable = true; }
    hm
    {
      _module.args.pkgs-unstable = pkgs-unstable;
      home-manager.users.guillaume = {
        gui.enable = false;
        codspeed.enable = false;
        programs.zsh.oh-my-zsh.theme = "gnzh";
      };
    }
  ];
}

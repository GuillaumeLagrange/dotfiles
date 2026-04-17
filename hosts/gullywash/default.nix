{
  inputs,
  pkgs-unstable,
  sshPublicKey,
  ...
}:

inputs.nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  specialArgs = { inherit pkgs-unstable sshPublicKey; };
  modules = [
    (import ../nixos-common.nix { inherit inputs; })
    ./configuration.nix
    {
      home-manager.users.guillaume = {
        gui.enable = false;
        codspeed.enable = false;
        programs.zsh.oh-my-zsh.theme = "gnzh";
      };
    }
  ];
}

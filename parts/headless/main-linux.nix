{
  flake.modules.homeManager.headless-linux =
    { pkgs, ... }:
    {
      home.packages = with pkgs; [
        killall
        nh
        pciutils
        usbutils
        yubioath-flutter
      ];

      home.shellAliases = {
        nfu = "nix flake update && nh os switch -a && gcam 'chore: update flake' ";
        scu = "systemctl --user";
        sc = "sudo systemctl";
      };

      programs.zsh.oh-my-zsh.plugins = [ "systemd" ];
    };
}

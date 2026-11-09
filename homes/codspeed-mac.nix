# codspeed-mac: the `codspeed` user of CodSpeed's mac mini.
{
  self,
  inputs,
  withSystem,
  ...
}:
{
  flake.modules.homeManager.codspeed-mac = {
    imports = with self.modules.homeManager; [
      core
      shell
      work
      (self.lib.zellijAccent "base0A")
    ];

    home.username = "codspeed";
    home.homeDirectory = "/Users/codspeed";

    programs.zsh.oh-my-zsh.theme = "gnzh";
    programs.gpg.settings.no-autostart = true;
  };

  flake.homeConfigurations.codspeed = withSystem "aarch64-darwin" (
    { pkgs, ... }:
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [ self.modules.homeManager.codspeed-mac ];
    }
  );
}

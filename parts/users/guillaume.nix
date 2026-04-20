{ self, ... }:
{
  flake.modules.homeManager.guillaume = {
    imports = with self.modules.homeManager; [
      base
      terminal
      headless
      gui
      codspeed
      stylix
    ];
  };

  flake.modules.homeManager.guillaume-headless = {
    imports = with self.modules.homeManager; [
      base
      terminal
      headless
      stylix
    ];

    programs.zsh.oh-my-zsh.theme = "gnzh";
  };
}

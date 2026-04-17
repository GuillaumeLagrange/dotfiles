{
  home.username = "codspeed";
  home.homeDirectory = "/Users/codspeed";

  gui.enable = false;
  stockly.enable = false;
  codspeed.enable = false;

  programs.zsh.oh-my-zsh.theme = "gnzh";
  # GPG agent is forwarded via SSH, prevent local auto-start
  programs.gpg.settings.no-autostart = true;
}

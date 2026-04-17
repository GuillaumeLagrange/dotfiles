{
  flake.modules.homeManager.headless-tmux-linux =
    { config, ... }:
    {
      wayland.windowManager.sway.config.keybindings =
        let
          modifier = "Mod4";
        in
        {
          "${modifier}+Backslash" = "kill; exec ${config.term} -e zsh -i -c tsm";
        };

      wayland.windowManager.hyprland.settings.bind = [
        "$mainMod, Backslash, exec, ${config.term} -e zsh -i -c tsm"
      ];
    };
}

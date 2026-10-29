{
  flake.modules.homeManager.lock =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    let
      # hyprlock reads its background once at start, from a fixed path: the lock
      # script points this at a random wallpaper of the pool, on every screen
      wallpaper = "${config.xdg.cacheHome}/hyprlock-wallpaper";

      lockScript = pkgs.writeShellScriptBin "lock.sh" ''
        # Suspend notification display
        ${pkgs.procps}/bin/pkill -u "$USER" -USR1 dunst

        # Ignore spotify because it's most of going to be playing on another player
        ${pkgs.playerctl}/bin/playerctl -i spotify pause

        # A random wallpaper of the pool
        ${pkgs.coreutils}/bin/mkdir -p "${config.xdg.cacheHome}"
        ${pkgs.coreutils}/bin/ln -sfn "$(${pkgs.findutils}/bin/find ${./wallpapers} -type f | ${pkgs.coreutils}/bin/shuf -n 1)" "${wallpaper}"

        # Lock computer
        ${pkgs.hyprlock}/bin/hyprlock

        # Resume notification display
        ${pkgs.procps}/bin/pkill -u "$USER" -USR2 dunst
      '';

      fg = "rgba(ddc7a1ee)";
      shadow = {
        shadow_passes = 2;
        shadow_size = 4;
        shadow_boost = 1.2;
      };
    in
    {
      options.lock = lib.mkOption {
        type = lib.types.path;
        default = "${lockScript}/bin/lock.sh";
        description = "Path to the lock script";
      };

      config = {
        programs.hyprlock = {
          enable = true;
          settings = {
            general = {
              hide_cursor = true;
            };
            auth = {
              "fingerprint:enabled" = true;
            };
            # stylix sets the colour, shown when the image is missing
            background = {
              path = wallpaper;
              blur_passes = 2;
              blur_size = 5;
              brightness = 0.7;
            };
            label = [
              (
                {
                  text = "$TIME";
                  font_family = "Inter Display";
                  font_size = 110;
                  color = fg;
                  position = "0, 170";
                  halign = "center";
                  valign = "center";
                }
                // shadow
              )
              (
                {
                  text = ''cmd[update:60000] date +"%A %-d %B"'';
                  font_family = "Inter";
                  font_size = 20;
                  color = fg;
                  position = "0, 70";
                  halign = "center";
                  valign = "center";
                }
                // shadow
              )
            ];
            input-field = {
              size = "280, 48";
              position = "0, -80";
              halign = "center";
              valign = "center";
              outline_thickness = 2;
              rounding = -1;
              fade_on_empty = true;
              placeholder_text = "";
              dots_spacing = 0.3;
            };
          };
        };

        home.packages = [
          lockScript
          # Needs: systemctl --user enable --now hyprpolkitagent.service
          # TODO: Patch soteria and get rid of this
          pkgs.hyprpolkitagent
        ];
      };
    };
}

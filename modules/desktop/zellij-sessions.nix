# Each zellij session gets a colour of the theme (pkgs/zellij-sessions): its zellij
# accent, its terminals' border in niri, its dot in the bar and in omp-panel. The
# palette is here; which session has which colour is set from omp-panel.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  colors = config.lib.stylix.colors.withHashtag;
  # Only hues far enough apart to tell at a glance as a dot: the theme's orange and
  # aqua sit too close to red/yellow and green/blue, and orange is the bar's focus.
  palette = [
    {
      name = "red";
      color = colors.base08;
    }
    {
      name = "yellow";
      color = colors.base0A;
    }
    {
      name = "green";
      color = colors.base0B;
    }
    {
      name = "blue";
      color = colors.base0D;
    }
    {
      name = "purple";
      color = colors.base0E;
    }
  ];
  stylixTheme = config.programs.zellij.themes.stylix.themes.default;
in
{
  _class = "homeManager";

  home.packages = [ pkgs.zellij-sessions ];

  xdg.configFile."zellij-sessions/palette.json".text = builtins.toJSON palette;

  # stylix's theme with the accent of `self.lib.zellijAccent` in the session's colour.
  programs.zellij.themes = lib.listToAttrs (
    map (
      swatch:
      lib.nameValuePair "session-${swatch.name}" {
        themes."session-${swatch.name}" = lib.recursiveUpdate stylixTheme {
          ribbon_selected.background = swatch.color;
          frame_selected.base = swatch.color;
          table_title.base = swatch.color;
        };
      }
    ) palette
  );
}

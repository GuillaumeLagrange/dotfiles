{
  self,
  inputs,
  withSystem,
  ...
}:
let
  mkHome =
    system: extraModules:
    withSystem system (
      { pkgs, ... }:
      inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = pkgs.extend self.overlays.default;
        modules = [
          self.modules.homeManager.guillaume-headless
        ]
        ++ extraModules;
      }
    );
in
{
  flake.homeConfigurations = {
    guillaume = mkHome "x86_64-linux" [ ];

    codspeed = mkHome "aarch64-darwin" [
      self.modules.homeManager.codspeed-headless
      {
        home.username = "codspeed";
        home.homeDirectory = "/Users/codspeed";

        programs.gpg.settings.no-autostart = true;
      }
      # yellow zellij accent, so a session here is distinguishable from other hosts
      ({ config, ... }: self.lib.zellij.accentTheme config.lib.stylix.colors.withHashtag.base0A)
    ];

    # Generic headless configuration that adapts to whoever runs it.
    # The username, home directory and system are resolved from the
    # environment so the same entry bootstraps any headless box (e.g. an
    # Ubuntu EC2 instance running as `ubuntu`). This relies on impure
    # evaluation: build it with `--impure` (see scripts/bootstrap-headless.sh).
    headless = mkHome (builtins.currentSystem) [
      self.modules.homeManager.codspeed-headless
      {
        home.username = builtins.getEnv "USER";
        home.homeDirectory = builtins.getEnv "HOME";
      }
      # blue zellij accent, so a session here is distinguishable from other hosts
      ({ config, ... }: self.lib.zellij.accentTheme config.lib.stylix.colors.withHashtag.base0D)
    ];
  };
}

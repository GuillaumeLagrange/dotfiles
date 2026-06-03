{ self, inputs, withSystem, ... }:
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
    guillaume = mkHome "x86_64-linux" [
      {
        home.username = "guillaume";
        home.homeDirectory = "/home/guillaume";
        home.stateVersion = "23.11";
      }
    ];

    codspeed = mkHome "aarch64-darwin" [
      {
        home.username = "codspeed";
        home.homeDirectory = "/Users/codspeed";
        home.stateVersion = "23.11";

        programs.gpg.settings.no-autostart = true;
      }
    ];

    # Generic headless configuration that adapts to whoever runs it.
    # The username, home directory and system are resolved from the
    # environment so the same entry bootstraps any headless box (e.g. an
    # Ubuntu EC2 instance running as `ubuntu`). This relies on impure
    # evaluation: build it with `--impure` (see scripts/bootstrap-headless.sh).
    headless = mkHome (builtins.currentSystem) [
      {
        home.username = builtins.getEnv "USER";
        home.homeDirectory = builtins.getEnv "HOME";
        home.stateVersion = "23.11";
      }
    ];
  };
}

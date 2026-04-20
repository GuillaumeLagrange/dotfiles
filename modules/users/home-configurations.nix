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
  };
}

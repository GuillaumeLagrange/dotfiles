# server: a machine without a screen.
{
  self,
  inputs,
  withSystem,
  ...
}:
{
  flake.modules.homeManager.server = {
    imports = with self.modules.homeManager; [
      core
      shell
    ];

    programs.zsh.oh-my-zsh.theme = "gnzh";
  };

  flake.homeConfigurations.guillaume = withSystem "x86_64-linux" (
    { pkgs, ... }:
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [ self.modules.homeManager.server ];
    }
  );
}

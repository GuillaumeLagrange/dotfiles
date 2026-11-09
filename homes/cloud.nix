# cloud: a headless box worked from (an EC2 instance, ...), as whoever runs it. User,
# home and system come from the environment, so `.#headless` needs `--impure`
# (scripts/bootstrap-headless.sh).
{
  self,
  inputs,
  withSystem,
  ...
}:
{
  flake.modules.homeManager.cloud = {
    imports = with self.modules.homeManager; [
      core
      shell
      work
      (self.lib.zellijAccent "base0D")
    ];

    home.username = builtins.getEnv "USER";
    home.homeDirectory = builtins.getEnv "HOME";

    programs.zsh.oh-my-zsh.theme = "gnzh";
  };

  flake.homeConfigurations.headless = withSystem builtins.currentSystem (
    { pkgs, ... }:
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [ self.modules.homeManager.cloud ];
    }
  );
}

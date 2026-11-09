# personal-desktop: a machine with a screen and no work on it.
{ self, ... }:
{
  flake.modules.homeManager.personal-desktop = {
    imports = with self.modules.homeManager; [
      core
      shell
      desktop
    ];
  };
}

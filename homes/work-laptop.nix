# work-laptop: a work machine with a screen.
{ self, ... }:
{
  flake.modules.homeManager.work-laptop = {
    imports = with self.modules.homeManager; [
      core
      shell
      desktop
      work
      work-desktop
    ];
  };
}

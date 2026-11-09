# shell: the terminal environment, on any machine, with or without a screen.
{ lib, ... }:
{
  # zsh, zellij and tmux, git, editors and language servers, CLI tools, omp's config.
  flake.modules.homeManager.shell = {
    imports = [
      ./tools.nix
      ./zsh.nix
      ./zellij.nix
      ./tmux.nix
      ./ai.nix
    ];
  };

  # A module recolouring zellij's accent to a stylix base16 colour, so a session on
  # another machine stands out: `self.lib.zellijAccent "base0D"`.
  flake.lib.zellijAccent =
    base:
    { config, ... }:
    let
      accent = config.lib.stylix.colors.withHashtag.${base};
    in
    {
      programs.zellij.themes.stylix.themes.default = {
        ribbon_selected.background = lib.mkForce accent;
        frame_selected.base = lib.mkForce accent;
        table_title.base = lib.mkForce accent;
      };
    };
}

# work: CodSpeed tooling.
{
  # 1Password and Oneleet.
  flake.modules.nixos.work = {
    imports = [ ./nixos.nix ];
  };

  # Any machine worked from, with or without a screen: codspeed tools, wt, review,
  # `cdr`, the work MCP servers.
  flake.modules.homeManager.work = {
    imports = [
      ./tools.nix
      ./review.nix
      ./omp.nix
      ./zsh.nix
    ];
  };

  # What a work machine with a screen adds: Slack, dbeaver, the bar's PR pill and
  # niri's review bindings (through `work.enable`).
  flake.modules.homeManager.work-desktop = {
    imports = [ ./desktop.nix ];
  };
}

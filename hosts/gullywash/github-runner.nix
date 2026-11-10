# Self-hosted runner for this repo's build workflow (.github/workflows/build.yml): its builds land in the
# store harmonia serves, and the out-links in /var/lib/ci-roots keep them from the GC.
{ lib, ... }:
{
  _class = "nixos";

  users.users.github-runner = {
    isSystemUser = true;
    group = "github-runner";
  };
  users.groups.github-runner = { };

  # Outside the runner's state directory, which the module wipes on every re-registration.
  systemd.tmpfiles.rules = [ "d /var/lib/ci-roots 0755 github-runner github-runner -" ];

  # nh clean deletes GC roots older than --keep-since; main's roots only move when main does.
  programs.nh.clean.extraArgs = lib.mkForce "--keep-since 7d --keep 3 --no-gcroots";

  services.github-runners.gullywash = {
    enable = true;
    url = "https://github.com/GuillaumeLagrange/dotfiles";
    tokenFile = "/var/lib/secrets/github-runner.token";
    extraLabels = [ "gullywash" ];
    replace = true;
    user = "github-runner";
    extraEnvironment.CI_ROOTS = "/var/lib/ci-roots";
    serviceOverrides.ReadWritePaths = [ "/var/lib/ci-roots" ];
  };
}

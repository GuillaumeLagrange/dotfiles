{
  # Passive recording for stutters with no known trigger:
  # - niri-stall.service logs each niri event-loop iteration over 30 ms, with
  #   where the time went, and every 5 s of reclaim the xe GPU buffer shrinker,
  #   evictions and fragmentation around it (header of niri-stall.bt;
  #   `journalctl -t niri-stall -t stutter` shows the marks too);
  # - below records cgroup and process memory, swap, PSI and IO every 5s, the
  #   context of a stall (`below replay -t "<time>"`);
  # - Mod+Ctrl+S (default.nix) logs a `stutter` mark when one is felt.
  # Off since ttm-reclaim.nix (hosts/granary) fixed the stalls; set `enable` to
  # turn the recording back on.
  flake.modules.nixos.niri =
    { lib, pkgs, ... }:
    let
      enable = false;
    in
    lib.mkIf enable {
      systemd.services.niri-stall = {
        description = "Log niri event-loop stalls";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.bpftrace}/bin/bpftrace -B line ${./niri-stall.bt} -- --threshold_ms=30";
          SyslogIdentifier = "niri-stall";
          Restart = "on-failure";
          RestartSec = "10s";
        };
      };

      services.below = {
        enable = true;
        compression.enable = true;
        collect.ioStats = true;
        retention = {
          time = 14 * 24 * 3600;
          size = 4 * 1024 * 1024 * 1024;
        };
      };
    };
}

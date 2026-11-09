# stall-tracing: records niri event-loop stalls (niri-stall.bt) and system pressure
# (`below`) to explain stutters; Mod+Ctrl+S marks a felt one. No host imports it: add
# it to one to record. `journalctl -t niri-stall -t stutter` shows what it logged.
{
  flake.modules.nixos.stall-tracing =
    { pkgs, ... }:
    {
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

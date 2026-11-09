{ pkgs, lib, ... }:
{
  _class = "homeManager";

  home.packages = [ pkgs.review ];

  systemd.user.services.reviews-refresh = {
    Unit.Description = "Refresh the reviews picker cache";
    Service = {
      Type = "oneshot";
      ExecStart = "${lib.getExe pkgs.reviews} --refresh";
    };
  };
  systemd.user.timers.reviews-refresh = {
    Unit = {
      Description = "Refresh the reviews picker cache every 5 minutes";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      # The default Before=timers.target makes an ordering cycle on stop.
      DefaultDependencies = false;
    };
    Timer = {
      OnActiveSec = "0";
      OnUnitActiveSec = "5min";
      RandomizedDelaySec = "30s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}

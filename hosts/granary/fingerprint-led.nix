# Blink the power button's LED while fprintd waits for a finger.
{ pkgs, ... }:
let
  # The 13 Pro's power LED is a one-channel multicolor LED named
  # chromeos:white:power, the watcher's default: its multicolor fallback and
  # colour selection never apply here.
  led = "/sys/class/leds/chromeos:white:power";

  fingerprint-led-blink = pkgs.stdenvNoCC.mkDerivation {
    pname = "framework-fingerprint-led-blink";
    version = "2.5";
    src = pkgs.fetchFromGitHub {
      owner = "alejandroqh";
      repo = "framework-fingerprint-led-blink";
      rev = "487d4b36c9d3f184ace3ccf332557aff9e04bbe1";
      hash = "sha256-cJIZFjjOu0Wze6uXOKbIfARl3BCPdVkuzpAhVh783YU=";
    };
    buildInputs = [ pkgs.python3 ];
    nativeCheckInputs = [ pkgs.python3 ];
    postPatch = ''
      substituteInPlace framework-fingerprint-led-blink \
        --replace-fail '["gdbus",' '["${pkgs.glib.bin}/bin/gdbus",'
    '';
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      python3 -m unittest discover -s tests
      runHook postCheck
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 framework-fingerprint-led-blink -t $out/bin
      runHook postInstall
    '';
    meta.mainProgram = "framework-fingerprint-led-blink";
  };
in
{
  _class = "nixos";

  # The service's only write access: the LED's trigger and brightness.
  users.groups.fprint-led = { };
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="leds", KERNEL=="chromeos:white:power", \
      RUN+="${pkgs.coreutils}/bin/chgrp fprint-led /sys%p/trigger /sys%p/brightness", \
      RUN+="${pkgs.coreutils}/bin/chmod g+w /sys%p/trigger /sys%p/brightness"
  '';

  systemd.services.fingerprint-led-blink = {
    description = "Blink the power button's LED while fprintd waits for a finger";
    wantedBy = [ "multi-user.target" ];
    after = [
      "dbus.service"
      "systemd-udevd.service"
    ];
    serviceConfig = {
      ExecStart = pkgs.lib.getExe fingerprint-led-blink;
      # Back to the EC, even after a crash.
      ExecStopPost = "-${pkgs.runtimeShell} -c 'echo chromeos-auto > ${led}/trigger'";
      Restart = "on-failure";
      RestartSec = 2;

      DynamicUser = true;
      SupplementaryGroups = [ "fprint-led" ];
      CapabilityBoundingSet = "";
      AmbientCapabilities = "";
      NoNewPrivileges = true;

      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      PrivateNetwork = true;
      RestrictAddressFamilies = "AF_UNIX";
      IPAddressDeny = "any";
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "@system-service"
        "~@privileged @resources"
      ];
      UMask = "0077";
    };
  };
}

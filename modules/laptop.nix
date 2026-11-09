# laptop: battery, lid and fingerprint reader.
{
  flake.modules.nixos.laptop =
    { pkgs, lib, ... }:
    {
      services.thermald.enable = true;
      powerManagement = {
        enable = true;
        powertop.enable = true;
      };

      services.logind.settings.Login = {
        HandleLidSwitch = "suspend-then-hibernate";
        HandlePowerKey = "suspend-then-hibernate";
      };
      systemd.sleep.settings.Sleep.HibernateDelaySec = "24h";

      services.fprintd.enable = true;
      systemd.services.fprintd = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.Type = "simple";
      };

      # sudo silences PAM modules by default, which would hide pam_echo below.
      security.sudo.extraConfig = ''
        Defaults !pam_silent
      '';

      # Print "Fingerprint accepted" after a match, which pam_fprintd does not: pam_echo
      # cannot end the stack, so pam_permit follows it; skip both on a failure.
      security.pam.services.sudo.rules.auth = {
        fprintd.control = lib.mkForce "[success=ok default=2]";
        fprintd-accepted = {
          order = 11450;
          control = "[default=ignore]";
          modulePath = "${pkgs.linux-pam}/lib/security/pam_echo.so";
          args = [ "Fingerprint accepted" ];
        };
        fprintd-done = {
          order = 11460;
          control = "[default=done]";
          modulePath = "${pkgs.linux-pam}/lib/security/pam_permit.so";
        };
      };
    };
}

{ config, pkgs, ... }:
let
  gMailConfigPath = "/configs/gmail";
in
{
  _class = "nixos";

  # A headless server cannot answer a refused import at boot.
  boot.zfs.forceImportRoot = true;

  # ARC limited to 4GB, 25% of the RAM.
  boot.kernelParams = [ "zfs.zfs_arc_max=4294967296" ];
  boot.extraModprobeConfig = ''
    # ABD scatter bloats memory under random I/O.
    options zfs zfs_abd_scatter_enabled=0
  '';

  programs.msmtp.enable = false;

  system.activationScripts.generateMsmtpConfig = ''
    smtp_user=$(cat ${gMailConfigPath}/smtp-user 2>/dev/null || echo "user@example.com")
    smtp_from=$(cat ${gMailConfigPath}/smtp-from 2>/dev/null || echo "user@example.com")
    target_email=$(cat ${gMailConfigPath}/target-email 2>/dev/null || echo "root@localhost")

    cat > /etc/msmtprc << EOF
    defaults
    aliases /etc/aliases
    port 587
    tls_trust_file /etc/ssl/certs/ca-certificates.crt
    tls on
    auth login

    account default
    host smtp.gmail.com
    user $smtp_user
    from $smtp_from
    passwordeval cat ${gMailConfigPath}/smtp-password
    EOF
    chmod 644 /etc/msmtprc

    cat > /etc/aliases << EOF
    root: $target_email
    zfs: $target_email
    EOF
  '';

  environment.systemPackages = with pkgs; [
    msmtp
    mailutils
  ];

  services.zfs = {
    autoScrub = {
      enable = true;
      interval = "monthly";
    };
    autoSnapshot = {
      enable = true;
      flags = "-k -p -u";
      weekly = 4;
      monthly = 0;
      daily = 0;
      hourly = 0;
      frequent = 0;
    };
    zed = {
      # Mail goes through msmtp (ZED_EMAIL_PROG); enableMail would force a sendmail wrapper.
      enableMail = false;
      settings = {
        ZED_EMAIL_ADDR = [ "root" ];

        ZED_EMAIL_PROG = "${pkgs.msmtp}/bin/msmtp";
        ZED_EMAIL_OPTS = "@ADDRESS@";

        ZED_NOTIFY_VERBOSE = "1";
        ZED_NOTIFY_DATA = "1";
        ZED_NOTIFY_POOL_IO_ERRORS = "1";
        ZED_NOTIFY_RESILVER_FINISH = "1";
        ZED_NOTIFY_SCRUB_FINISH = "1";
        ZED_NOTIFY_SCRUB_START = "1";
        ZED_NOTIFY_STATECHANGE = "1";
      };
    };
  };

}

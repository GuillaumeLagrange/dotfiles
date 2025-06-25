{ config, pkgs, ... }:
let
  gMailConfigPath = "/configs/gmail";
in
{
  programs.msmtp.enable = false;

  system.activationScripts.generateMsmtpConfig = ''
    smtp_user=$(cat ${gMailConfigPath}/smtp-user 2>/dev/null || echo "user@example.com")
    smtp_from=$(cat ${gMailConfigPath}/smtp-from 2>/dev/null || echo "user@example.com")
    target_email=$(cat ${gMailConfigPath}/target-email 2>/dev/null || echo "root@localhost")

    # Generate msmtp config
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

    # Generate aliases file
    cat > /etc/aliases << EOF
    root: $target_email
    zfs: $target_email
    EOF
  '';

  environment.systemPackages = with pkgs; [
    msmtp
    mailutils
  ];

  # ZFS configuration
  services.zfs = {
    autoScrub = {
      enable = true;
      interval = "monthly";
    };
    zed = {
      enableMail = true;
      settings = {
        # Use array format for email addresses (recommended)
        ZED_EMAIL_ADDR = [ "root" ];

        ZED_EMAIL_PROG = "${pkgs.msmtp}/bin/msmtp";
        ZED_EMAIL_OPTS = "@ADDRESS@";

        # Enable verbose logging for debugging
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

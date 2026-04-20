{ config, pkgs, ... }:
let
  gMailConfigPath = "/configs/gmail";
in
{
  # ZFS tuning
  # Limit ZFS ARC to 4GB (25% of 16GB RAM)
  boot.kernelParams = [ "zfs.zfs_arc_max=4294967296" ];
  # ZFS module parameters
  boot.extraModprobeConfig = ''
    # Disable ABD scatter to prevent memory bloat with random I/O workloads
    options zfs zfs_abd_scatter_enabled=0

    # Optional: If you want to set a higher minimum size for scatter (if re-enabled later)
    # options zfs zfs_abd_scatter_min_size=16777216

    # Optional: Other memory-related tunings for 16GB system
    # options zfs zfs_arc_min=2147483648             # 2GB minimum ARC
    # options zfs zfs_arc_meta_limit_percent=50      # Limit metadata to 50% of ARC
    # options zfs zfs_arc_sys_free=1073741824        # Keep 1GB system memory free
  '';

  # Notifications
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

  services.zfs = {
    autoScrub = {
      enable = true;
      interval = "monthly";
    };
    autoSnapshot = {
      enable = true;
      flags = "-k -p -u";
      weekly = 4; # Keep 4 weekly snapshots
      monthly = 0; # Disable monthly snapshots
      daily = 0; # Disable daily snapshots
      hourly = 0; # Disable hourly snapshots
      frequent = 0; # Disable frequent snapshots
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

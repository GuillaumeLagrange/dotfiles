{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.programs.oneleet;
in
{
  _class = "nixos";

  options.programs.oneleet = {
    enable = mkEnableOption "OneLeet";

    package = mkOption {
      type = types.package;
      default = pkgs.stdenv.mkDerivation {
        name = "oneleet";
        version = "2.3.5";

        src = pkgs.fetchurl {
          url = "https://downloads.oneleet.com/agent/linux/Oneleet_2.3.5_amd64.deb";
          sha256 = "sha256-u9r2arf0HKXKpoj+CFmNwELGN8uwhfGHhXpEsSzJoPw=";
        };

        nativeBuildInputs = with pkgs; [
          dpkg
          autoPatchelfHook
          makeWrapper
        ];

        buildInputs = with pkgs; [
          alsa-lib
          glib
          gtk3
          libsecret
          gnome-keyring
          libgnome-keyring
          nss
          nspr
          at-spi2-atk
          cups
          dbus
          libdrm
          libxkbcommon
          mesa
          pango
          stdenv.cc.cc
          libx11
          libxcomposite
          libxdamage
          libxext
          libxfixes
          libxrandr
        ];

        # chrome-sandbox is setuid in the deb, which the Nix sandbox rejects.
        unpackPhase = ''
          dpkg-deb --fsys-tarfile $src | tar -x --no-same-owner --no-same-permissions
        '';

        installPhase = ''
          echo "Installing OneLeet..."
          mkdir -p $out

          if [ -d usr ]; then
            cp -R usr/* $out/
          fi

          if [ -d opt ]; then
            mkdir -p $out/opt
            cp -R opt/* $out/opt/

            mkdir -p $out/bin
            find $out/opt -type f -executable \( -name "*oneleet*" -o -name "*Oneleet*" \) | while read executable; do
              basename=$(basename "$executable")
              if [ ! -e "$out/bin/''${basename,,}" ]; then
                ln -s "$executable" "$out/bin/''${basename,,}"
                echo "Created symlink for $executable to $out/bin/''${basename,,}"
              fi
            done
          fi

          if [ -e "$out/bin/oneleet-agent" ]; then
            mv $out/bin/oneleet-agent $out/bin/oneleet-agent-unwrapped
            makeWrapper $out/bin/oneleet-agent-unwrapped $out/bin/oneleet-agent \
              --prefix LD_LIBRARY_PATH : $out/lib:$out/lib64 \
              --add-flags "--password-store=gnome-libsecret"
            echo "Created wrapper for oneleet-agent with libsecret password store flag"
          fi
        '';

        meta = with lib; {
          description = "OneLeet application";
          homepage = "https://oneleet.com";
          license = licenses.unfree;
        };
      };
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # Oneleet's firewall check wants a drop policy on the input hook chain itself,
    # which the iptables firewall (a jump to nixos-fw) lacks.
    networking.nftables.enable = true;

    system.activationScripts = {
      createOneLeetLinks = {
        text = ''
          mkdir -p /usr/bin
          ln -sf ${cfg.package}/bin/oneleet-agent /usr/bin/oneleet-agent || true
        '';
        deps = [ ];
      };
    };

    systemd.tmpfiles.rules = [
      "d /etc/oneleet 0755 root root -"
      "d /var/log/oneleet 0755 root root -"
    ];

    systemd.services.oneleet-daemon = {
      description = "OneLeet daemon";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # nft: the firewall check runs `nft --json list ruleset` from PATH.
      path = with pkgs; [
        util-linux
        nftables
      ];

      serviceConfig = {
        ExecStart = "${cfg.package}/opt/Oneleet/oneleet-daemon";
        Restart = "always";
        RestartSec = 5;
        User = "root";
        # World-readable socket so the user-launched agent can connect.
        UMask = "0000";
      };
    };
  };
}

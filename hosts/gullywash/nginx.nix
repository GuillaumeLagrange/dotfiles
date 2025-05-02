{ config, pkgs, ... }:

{
  services.nginx = {
    enable = true;

    virtualHosts."radarr.glagrange.eu" = {
      listen = [
        { addr = "80"; }
        { addr = "[::]:80"; }
      ];
      serverName = "radarr.glagrange.eu";

      locations."/" = {
        return = ''
          301 "https://$host$request_uri"';
        '';
      };

      allowList = [
        "127.0.0.1"
        "::1"
        "192.168.1.0/24"
        "10.26.198.0/24"
      ];
      denyAll = true;
    };

    virtualHosts."radarr.glagrange.eu-ssl" = {
      listen = [
        {
          addr = "443 ssl";
          http2 = true;
        }
        {
          addr = "[::]:443 ssl";
          http2 = true;
        }
      ];
      serverName = "radarr.glagrange.eu";

      sslCertificate = "/etc/letsencrypt/live/glagrange.eu-0002/fullchain.pem";
      sslCertificateKey = "/etc/letsencrypt/live/glagrange.eu-0002/privkey.pem";
      sslDHParam = "/etc/letsencrypt/ssl-dhparams.pem";
      sslTrustedCertificate = "/etc/letsencrypt/live/glagrange.eu-0002/chain.pem";
      sslOptions = ''
        include /etc/letsencrypt/options-ssl-nginx.conf;
      '';

      extraConfig = ''
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
      '';

      locations."/" = {
        proxyPass = "http://127.0.0.1:7878/";
        proxySetHeader = [
          "Host $host"
          "X-Real-IP $remote_addr"
          "X-Forwarded-For $proxy_add_x_forwarded_for"
          "X-Forwarded-Proto $scheme"
        ];
      };

      allowList = [
        "127.0.0.1"
        "::1"
        "192.168.1.0/24"
        "10.26.198.0/24"
      ];
      denyAll = true;
    };
  };

  # Enable the firewall and open the necessary ports
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
  networking.firewall.allowedUDPPorts = [ ];
}

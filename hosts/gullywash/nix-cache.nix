# Binary cache served from gullywash's own store.
{
  _class = "nixos";

  services.harmonia.cache = {
    enable = true;
    # Public half: nix-cache.gullywash.glagrange.eu-1:gUOrdYrUIclZrkIsIvQAgja2UZVzlx5JbTfgN++pV9Y=
    signKeyPaths = [ "/var/lib/secrets/harmonia.secret" ];
  };

  # Traefik reverse proxy
  networking.firewall.interfaces."br-+".allowedTCPPorts = [ 5000 ];
}

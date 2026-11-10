# gullywash's binary cache (hosts/gullywash/README.md). The password lives in /etc/nix/netrc, written by hand;
# without it the cache answers 401 and Nix carries on with cache.nixos.org.
{
  _class = "nixos";

  nix.settings = {
    extra-substituters = [ "https://nix-cache.gullywash.glagrange.eu" ];
    extra-trusted-public-keys = [
      "nix-cache.gullywash.glagrange.eu-1:gUOrdYrUIclZrkIsIvQAgja2UZVzlx5JbTfgN++pV9Y="
    ];
    netrc-file = "/etc/nix/netrc";
    connect-timeout = 5;
    fallback = true;
  };
}

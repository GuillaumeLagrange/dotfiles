{ inputs, ... }:
{
  systems = [
    "x86_64-linux"
    "aarch64-linux"
    "aarch64-darwin"
  ];

  perSystem =
    { system, ... }:
    {
      _module.args.pkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      overlayAttrs = {
        # quickshell's own `packages` re-instantiate nixpkgs-unstable with its overlay.
        unstable = import inputs.nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
          overlays = [ inputs.quickshell.overlays.default ];
        };
      };
    };
}

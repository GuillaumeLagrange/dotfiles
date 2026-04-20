{ inputs, ... }:
{
  perSystem =
    { system, ... }:
    {
      overlayAttrs = {
        unstable = import inputs.nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        };
      };
    };
}

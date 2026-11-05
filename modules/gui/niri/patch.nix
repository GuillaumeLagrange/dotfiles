{
  perSystem =
    { pkgs, ... }:
    {
      # In the overview a plain middle click closes the window under the pointer, and
      # `hot-corners` take `delay-ms` and `barrier` (see mouse.patch). Upstream: niri-wm/niri#1473
      # (barrier), #2987 (delay), discussion #1534 (middle click).
      overlayAttrs.niri = pkgs.niri.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./mouse.patch ];
      });
    };
}

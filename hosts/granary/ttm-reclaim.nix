# ttm.ko with a `max_reclaim_order` parameter (https://patchwork.freedesktop.org/patch/716404/),
# set to 0: xe's 2 MB GPU allocations stop waking kswapd, whose shrinker evicted every
# app's GPU buffers and stalled niri. Writing 10 to
# /sys/module/ttm/parameters/max_reclaim_order restores upstream behaviour live.
{ config, ... }:
let
  ttm = config.boot.kernelPackages.callPackage (
    {
      stdenv,
      kernel,
      kernelModuleMakeFlags,
    }:
    stdenv.mkDerivation {
      pname = "ttm-max-reclaim-order";
      inherit (kernel) version src;

      unpackPhase = ''
        tar xf $src --strip-components=1 --wildcards '*/drivers/gpu/drm/ttm/*'
      '';
      patches = [ ./ttm-max-reclaim-order.patch ];

      nativeBuildInputs = kernel.moduleBuildDependencies;
      hardeningDisable = [
        "pic"
        "format"
      ];

      buildPhase = ''
        runHook preBuild
        make ${toString kernelModuleMakeFlags} \
          -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
          M=$PWD/drivers/gpu/drm/ttm modules
        runHook postBuild
      '';

      # updates/ wins over the in-tree ttm.ko.
      installPhase = ''
        install -Dm444 drivers/gpu/drm/ttm/ttm.ko \
          $out/lib/modules/${kernel.modDirVersion}/updates/ttm.ko
      '';
    }
  ) { };
in
{
  _class = "nixos";

  boot.extraModulePackages = [ ttm ];
  boot.kernelParams = [ "ttm.max_reclaim_order=0" ];
}

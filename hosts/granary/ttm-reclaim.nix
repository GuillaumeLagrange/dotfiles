{
  # ttm.ko with a `max_reclaim_order` parameter, after Daniel Colascione's RFC
  # (https://patchwork.freedesktop.org/patch/716404/): GPU buffer allocations above
  # that order neither reclaim nor wake kswapd, and fall back to smaller pages.
  # On fragmented memory, xe's 2 MB allocations otherwise wake kswapd, whose xe
  # shrinker evicts every app's GPU buffers; the apps restore them holding the
  # buffer locks niri composites with, and niri stalls
  # (modules/gui/niri/stall-tracing.nix). The default keeps upstream behaviour;
  # /sys/module/ttm/parameters/max_reclaim_order switches it live.
  # Built out of tree against the configured kernel, so a kernel bump rebuilds one
  # module, provided the patch still applies.
  flake.modules.nixos.granary =
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

          # updates/ takes precedence over the in-tree ttm.ko in depmod's search order.
          installPhase = ''
            install -Dm444 drivers/gpu/drm/ttm/ttm.ko \
              $out/lib/modules/${kernel.modDirVersion}/updates/ttm.ko
          '';
        }
      ) { };
    in
    {
      boot.extraModulePackages = [ ttm ];
    };
}

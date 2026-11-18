# btintel_pcie.ko with Intel's PM fixes from 7.4 (bluetooth-next 12997a385f71, 2926eb396711,
# 4f6ead67b93b, f2cee6e2aa35). In 7.3, .thaw FLRs and re-probes the controller as if power had
# been lost; that firmware reload runs while the image is written, so .poweroff gets no alive
# interrupt, returns -EBUSY and aborts hibernation. Drop once the kernel carries them.
{ config, ... }:
let
  btintel-pcie = config.boot.kernelPackages.callPackage (
    {
      stdenv,
      kernel,
      kernelModuleMakeFlags,
    }:
    stdenv.mkDerivation {
      pname = "btintel-pcie-pm-fixes";
      inherit (kernel) version src;

      unpackPhase = ''
        tar xf $src --strip-components=1 --wildcards '*/drivers/bluetooth/*'
      '';
      patches = [
        ./btintel-pcie-1-fix-stale-cache-in-set-dxstate-fallback.patch
        ./btintel-pcie-2-fix-pm-flow-for-s0ix-s3-and-s4.patch
        ./btintel-pcie-3-verify-and-serialize-d-state-transitions.patch
        ./btintel-pcie-4-clear-the-gp0-cause-with-a-w1c-write.patch
      ];

      nativeBuildInputs = kernel.moduleBuildDependencies;
      hardeningDisable = [
        "pic"
        "format"
      ];

      buildPhase = ''
        runHook preBuild
        make ${toString kernelModuleMakeFlags} \
          -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
          M=$PWD/drivers/bluetooth CONFIG_BT_INTEL_PCIE=m btintel_pcie.ko
        runHook postBuild
      '';

      # updates/ wins over the in-tree btintel_pcie.ko.
      installPhase = ''
        install -Dm444 drivers/bluetooth/btintel_pcie.ko \
          $out/lib/modules/${kernel.modDirVersion}/updates/btintel_pcie.ko
      '';
    }
  ) { };
in
{
  _class = "nixos";

  boot.extraModulePackages = [ btintel-pcie ];
}

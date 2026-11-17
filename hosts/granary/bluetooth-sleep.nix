# btintel_pcie sometimes refuses to power off (EBUSY), which aborts hibernation; the rollback
# then breaks xe's USB-C display output and freezes the screen. Unloaded, it has nothing to refuse.
# Hibernation only: reloading it right after s2idle crashed its interrupt handler and wedged it.
# SYSTEMD_SLEEP_ACTION is the phase, so suspend-then-hibernate unloads it only before hibernating.
{ pkgs, ... }:
{
  _class = "nixos";

  environment.etc."systemd/system-sleep/btintel-pcie".source =
    pkgs.writeShellScript "btintel-pcie-sleep" ''
      [ "$SYSTEMD_SLEEP_ACTION" = hibernate ] || exit 0
      case "$1" in
        pre) ${pkgs.kmod}/bin/modprobe -r btintel_pcie ;;
        # In the background: a load that hangs must not hold up the resume.
        post) ${pkgs.kmod}/bin/modprobe btintel_pcie & ;;
      esac
    '';
}

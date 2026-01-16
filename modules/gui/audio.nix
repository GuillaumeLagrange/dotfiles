{
  lib,
  config,
  ...
}:
let
  # List of Bluetooth devices with their MAC address and priority
  # Higher priority = preferred device
  bluetoothDevices = [
    { mac = "40:B3:FA:21:39:77"; priority = 2001; } # Airpods
    { mac = "AC:80:0A:6F:E5:88"; priority = 2000; } # WH1000-XM5
  ];

  # Convert MAC address format from AA:BB:CC to AA_BB_CC
  macToDeviceName = mac: "~bluez_card.${lib.replaceStrings [":"] ["_"] mac}";

  # Generate a WirePlumber rule for a device
  mkDeviceRule = device: ''
    {
      matches = [
        {
          device.name = "${macToDeviceName device.mac}"
        }
      ]
      actions = {
        update-props = {
          device.priority = ${toString device.priority}
        }
      }
    }
  '';
in
{
  config = lib.mkIf config.gui.enable {
    xdg.configFile."wireplumber/wireplumber.conf.d/90-bluetooth-priority.conf".text = ''
      monitor.bluez.rules = [
        ${lib.concatStringsSep "\n    " (map mkDeviceRule bluetoothDevices)}
      ]
    '';
  };
}

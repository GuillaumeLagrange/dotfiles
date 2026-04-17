{
  lib,
  config,
  ...
}:
let
  # List of Bluetooth devices with their MAC address and priority
  # Higher priority = preferred device
  bluetoothDevices = [
    {
      # Airpods
      mac = "40:B3:FA:21:39:77";
      priority = 2001;
    }
    {
      # WH1000-XM5
      mac = "AC:80:0A:6F:E5:88";
      priority = 2000;
    }
  ];

  # Convert MAC address format from AA:BB:CC to AA_BB_CC
  macToDeviceName = mac: "bluez_output.${lib.replaceStrings [ ":" ] [ "_" ] mac}.a2dp-sink";

  # Generate a WirePlumber rule for a device
  mkDeviceRule = device: ''
    {
      matches = [
        {
          node.name = "${macToDeviceName device.mac}"
        }
      ]
      actions = {
        update-props = {
          device.priority = ${toString device.priority}
        }
      }
    }'';
in
{
  config = lib.mkIf config.gui.enable {
    xdg.configFile."wireplumber/wireplumber.conf.d/90-bluetooth-priority.conf".text = ''
      monitor.bluez.rules = [
      ${lib.concatMapStringsSep ",\n" mkDeviceRule bluetoothDevices}
      ]
    '';
  };
}

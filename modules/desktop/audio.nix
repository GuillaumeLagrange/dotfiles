{ lib, ... }:
let
  # Bluetooth devices with priority (higher wins).
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

  macToDeviceName = mac: "bluez_output.${lib.replaceStrings [ ":" ] [ "_" ] mac}.a2dp-sink";

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
  _class = "homeManager";

  xdg.configFile."wireplumber/wireplumber.conf.d/90-bluetooth-priority.conf".text = ''
    monitor.bluez.rules = [
    ${lib.concatMapStringsSep ",\n" mkDeviceRule bluetoothDevices}
    ]
  '';

  # alsa-ucm-conf's DualSense profile exposes only a mono speaker (hw channel 1), so chiaki-ng's
  # haptics get downmixed into the speaker. Without UCM the card is a 4.0 sink and RL/RR reach the actuators.
  xdg.configFile."wireplumber/wireplumber.conf.d/51-dualsense-no-ucm.conf".text = ''
    monitor.alsa.rules = [
      {
        matches = [
          {
            device.name = "~alsa_card.usb-Sony_Interactive_Entertainment_DualSense_Wireless_Controller-.*"
          }
        ]
        actions = {
          update-props = {
            api.alsa.use-ucm = false
          }
        }
      }
    ]
  '';
}

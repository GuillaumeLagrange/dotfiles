{
  flake.modules.homeManager.audio =
    { pkgs, lib, ... }:
    let
      wpctl = "${pkgs.wireplumber}/bin/wpctl";
      volumeNotification = "${pkgs.pulseaudio}/bin/paplay ${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/audio-volume-change.oga";

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
      options.audio = {
        up = lib.mkOption {
          type = lib.types.str;
          default = "${wpctl} set-mute @DEFAULT_AUDIO_SINK@ 0 && ${wpctl} set-volume @DEFAULT_AUDIO_SINK@ 5%+ --limit 1.0 && ${volumeNotification}";
        };

        down = lib.mkOption {
          type = lib.types.str;
          default = "${wpctl} set-mute @DEFAULT_AUDIO_SINK@ 0 && ${wpctl} set-volume @DEFAULT_AUDIO_SINK@ 5%- && ${volumeNotification}";
        };

        mute = lib.mkOption {
          type = lib.types.str;
          default = "${wpctl} set-mute @DEFAULT_AUDIO_SINK@ toggle && ${volumeNotification}";
        };
      };

      config = {
        xdg.configFile."wireplumber/wireplumber.conf.d/90-bluetooth-priority.conf".text = ''
          monitor.bluez.rules = [
          ${lib.concatMapStringsSep ",\n" mkDeviceRule bluetoothDevices}
          ]
        '';
      };
    };
}

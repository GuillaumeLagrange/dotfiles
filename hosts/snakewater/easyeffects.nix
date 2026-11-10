# Arctis Nova Pro Wireless: the headphone EQ and mic EQ of
# github.com/CLEMENTINATOR/dotfiles (modules/desktop/easyeffects/), plus a gate on the mic
# after RNNoise.
{
  _class = "homeManager";

  easyeffects.autoload = {
    Arctis-Nova-Pro = {
      device = "alsa_output.usb-SteelSeries_Arctis_Nova_Pro_Wireless-00.analog-stereo";
      description = "Arctis Nova Pro Wireless Analog Stereo";
      profile = "Analog Output";
      preset = ./Arctis-Nova-Pro.json;
    };
    Arctis-Nova-Pro-Mic = {
      device = "alsa_input.usb-SteelSeries_Arctis_Nova_Pro_Wireless-00.mono-fallback";
      description = "Arctis Nova Pro Wireless Mono";
      profile = "Microphone";
      preset = ./Arctis-Nova-Pro-Mic.json;
    };
  };
}

# Framework's Windows Dolby tuning for this codec (DEV_0285_SUBSYS_F111000F),
# converted by github.com/antoinecellerier/speaker-tuning-to-easyeffects
# with `--profile music`.
let
  speakersKernel = "Dolby-Music-Balanced-cbb9a4b9";
in
{
  _class = "homeManager";

  easyeffects.autoload.Dolby-Music-Balanced = {
    device = "alsa_output.pci-0000_00_1f.3.analog-stereo";
    description = "Built-in Audio";
    profile = "Speakers";
    preset = ./Dolby-Music-Balanced.json;
  };

  xdg.dataFile."easyeffects/irs/${speakersKernel}.irs".source = ./${speakersKernel}.irs;
}

# Framework's Windows Dolby tuning for this codec (DEV_0285_SUBSYS_F111000F),
# converted by github.com/antoinecellerier/speaker-tuning-to-easyeffects
# with `--profile music`.
{ pkgs, lib, ... }:
let
  speakersPreset = "Dolby-Music-Balanced";
  speakersKernel = "Dolby-Music-Balanced-cbb9a4b9";
  flatPreset = "Flat";
  kwriteconfig = "${pkgs.kdePackages.kconfig}/bin/kwriteconfig6";
in
{
  _class = "homeManager";

  services.easyeffects = {
    enable = true;
    extraPresets = {
      ${speakersPreset} = lib.importJSON ./${speakersPreset}.json;
      ${flatPreset}.output = {
        blocklist = [ ];
        plugins_order = [ ];
      };
    };
  };

  xdg.dataFile."easyeffects/irs/${speakersKernel}.irs".source = ./${speakersKernel}.irs;

  xdg.dataFile."easyeffects/autoload/output/alsa_output.pci-0000_00_1f.3.analog-stereo:Speakers.json".text =
    builtins.toJSON {
      device = "alsa_output.pci-0000_00_1f.3.analog-stereo";
      device-description = "Built-in Audio";
      device-profile = "Speakers";
      preset-name = speakersPreset;
    };

  home.activation.easyeffectsFallback = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${kwriteconfig} --file easyeffects/db/easyeffectsrc --group Window \
      --key outputAutoloadingUsesFallback true
    run ${kwriteconfig} --file easyeffects/db/easyeffectsrc --group Window \
      --key outputAutoloadingFallbackPreset ${flatPreset}
  '';
}

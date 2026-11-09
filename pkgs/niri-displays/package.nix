{
  writers,
  niri,
  libnotify,
}:
writers.writePython3Bin "niri-displays" { doCheck = false; } (
  builtins.replaceStrings
    [ "@niri@" "@notifySend@" ]
    [ "${niri}/bin/niri" "${libnotify}/bin/notify-send" ]
    (builtins.readFile ./displays.py)
)

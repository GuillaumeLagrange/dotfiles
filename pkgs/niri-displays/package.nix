{
  writers,
  niri,
}:
writers.writePython3Bin "niri-displays" { doCheck = false; } (
  builtins.replaceStrings [ "@niri@" ] [ "${niri}/bin/niri" ] (builtins.readFile ./displays.py)
)

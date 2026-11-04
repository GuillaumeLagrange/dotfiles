{ writers }:
writers.writePython3Bin "niri-workspaces" { doCheck = false; } (builtins.readFile ./workspaces.py)

# Keyboard backlight on while typing or using the trackpad, faded out after 10s idle.
{ pkgs, ... }:
let
  keylightd = pkgs.rustPlatform.buildRustPackage {
    pname = "keylightd";
    version = "0-unstable-933a4cf";
    src = pkgs.fetchFromGitHub {
      owner = "jonas-schievink";
      repo = "keylightd";
      rev = "933a4cf851009d4a8c1b4ce7725556d69d4b82db";
      hash = "sha256-lU5ddVRjiGts7IzkoL3CWJVtjoiBMIHRBxb/C0n+oqQ=";
    };
    cargoHash = "sha256-P3kJM4TI33ug5hmTLer91Wy1eVJGgtPRbvftqI3tbvY=";
    # This board's touchpad id, and a lock guard newer rustc refuses to discard.
    postPatch = ''
      substituteInPlace src/main.rs \
        --replace-fail "093A:0274 Touchpad" "093A:1343 Touchpad" \
        --replace-fail "let (_, result) = act" "let (guard, result) = act" \
        --replace-fail "let new_state = " "drop(guard); let new_state = "
    '';
    meta.mainProgram = "keylightd";
  };
in
{
  _class = "nixos";

  systemd.services.keylightd = {
    description = "Keyboard backlight daemon";
    wantedBy = [ "multi-user.target" ];
    startLimitIntervalSec = 500;
    startLimitBurst = 5;
    serviceConfig = {
      Type = "exec";
      ExecStart = "${pkgs.lib.getExe keylightd} --brightness 20 --timeout 10";
      Restart = "on-failure";
      RestartSec = "1s";
    };
  };
}

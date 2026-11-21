# The daemon behind the bar's launcher panel. See AGENTS.md.
{
  lib,
  rustPlatform,
  makeWrapper,
  pkg-config,
  coreutils,
  dbus,
  niri,
  sqlite,
  sway-unwrapped,
  wl-clipboard,
  xdg-terminal-exec,
  xdg-utils,
  zellij,
  zellij-attach,
}:

let
  # Run from a systemd unit: everything it calls goes on its PATH. Programs it hands to niri
  # are resolved here too, so they do not depend on the session's PATH.
  runtimeInputs = [
    coreutils # env -C for desktop entries with a Path
    niri
    xdg-terminal-exec
    xdg-utils
    zellij
    zellij-attach
  ];
in
rustPlatform.buildRustPackage {
  pname = "launcher";
  version = "0.1.0";
  # With pkgs/zellij-sessions, a path dependency.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ./crates
      ./Cargo.toml
      ./Cargo.lock
      ./.config
      ../zellij-sessions/src
      ../zellij-sessions/Cargo.toml
    ];
  };
  cargoRoot = "launcher";
  buildAndTestSubdir = "launcher";
  cargoLock.lockFile = ./Cargo.lock;

  # nixpkgs' cargo hook makes rusqlite link the system sqlite (LIBSQLITE3_SYS_USE_PKG_CONFIG)
  # rather than build its bundled copy.
  nativeBuildInputs = [
    makeWrapper
    pkg-config
  ];
  buildInputs = [ sqlite ];
  # What the tests drive, which fail rather than skip without it: the clipboard's and the
  # daemon's against a headless sway (unwrapped: the wrapper starts it under dbus-run-session,
  # absent from the sandbox), the browser's against a private bus.
  useNextest = true;
  nativeCheckInputs = [
    dbus
    sway-unwrapped
    wl-clipboard
  ];

  postInstall = ''
    wrapProgram $out/bin/launcher --prefix PATH : ${lib.makeBinPath runtimeInputs}
  '';

  meta.mainProgram = "launcher";
}

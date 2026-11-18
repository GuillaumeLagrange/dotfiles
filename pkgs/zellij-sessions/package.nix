# Each zellij session's colour, order and folding, shared by omp-panel, the bar,
# zellij and niri. See src/lib.rs.
{
  lib,
  rustPlatform,
  makeWrapper,
  zellij,
}:

rustPlatform.buildRustPackage {
  pname = "zellij-sessions";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./src
      ./Cargo.toml
      ./Cargo.lock
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [ makeWrapper ];
  postInstall = ''
    wrapProgram $out/bin/zellij-sessions --prefix PATH : ${lib.makeBinPath [ zellij ]}
  '';

  meta.mainProgram = "zellij-sessions";
}

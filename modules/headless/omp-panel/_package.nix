# Underscore-prefixed so import-tree does not treat it as a flake module.
{
  lib,
  rustPlatform,
  makeWrapper,
  zellij,
  # Argv prefix that runs a command in a new terminal window.
  termExec,
  # Attaches to a session by name, the way zsm does.
  attach,
}:

rustPlatform.buildRustPackage {
  pname = "omp-panel";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./src
      ./tests
      ./Cargo.toml
      ./Cargo.lock
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [ makeWrapper ];
  # The zellij tests skip without zellij and `script` on PATH: a zellij server
  # in the build sandbox is not something to make the package depend on. `just
  # test` runs them.

  # niri is looked up on PATH: a host without it jumps inside zellij instead.
  postInstall = ''
    wrapProgram $out/bin/omp-panel \
      --prefix PATH : ${lib.makeBinPath [ zellij ]} \
      --set OMP_PANEL_TERM_EXEC ${lib.escapeShellArg (builtins.toJSON termExec)} \
      --set OMP_PANEL_ATTACH ${attach}
  '';

  meta.mainProgram = "omp-panel";
}

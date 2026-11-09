{
  lib,
  rustPlatform,
  makeWrapper,
  zellij,
  git,
  zellij-attach,
}:

let
  termExec = [ "xdg-terminal-exec" ];
in

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
  postInstall = ''
    wrapProgram $out/bin/omp-panel \
      --prefix PATH : ${
        lib.makeBinPath [
          zellij
          git
        ]
      } \
      --set OMP_PANEL_TERM_EXEC ${lib.escapeShellArg (builtins.toJSON termExec)} \
      --set OMP_PANEL_ATTACH ${zellij-attach}/bin/zellij-attach
  '';

  meta.mainProgram = "omp-panel";
}

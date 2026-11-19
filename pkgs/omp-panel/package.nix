{
  lib,
  rustPlatform,
  makeWrapper,
  zellij,
  git,
  zellij-attach,
  util-linux,
}:

let
  termExec = [ "xdg-terminal-exec" ];
in

rustPlatform.buildRustPackage {
  pname = "omp-panel";
  version = "0.1.0";
  # With pkgs/zellij-sessions, a path dependency.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ./src
      ./tests
      ./Cargo.toml
      ./Cargo.lock
      ./.config
      ../zellij-sessions/src
      ../zellij-sessions/Cargo.toml
    ];
  };
  cargoRoot = "omp-panel";
  buildAndTestSubdir = "omp-panel";
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [ makeWrapper ];
  # What the tests drive, which fail rather than skip without it.
  useNextest = true;
  nativeCheckInputs = [
    zellij
    util-linux
  ];
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

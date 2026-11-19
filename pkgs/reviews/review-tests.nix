# tests/review.rs: review.sh end to end, against the wt built from this tree. A check rather
# than part of `reviews`, which they do not test and whose build would otherwise follow
# zellij's config.
{
  lib,
  rustPlatform,
  wt,
  zellij,
  zellij-sessions,
  git,
  jq,
  gawk,
  gnugrep,
  util-linux,
}:

rustPlatform.buildRustPackage {
  pname = "review-tests";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ./src
      ./tests
      ./Cargo.toml
      ./Cargo.lock
      ./.config
      ./review.sh
      ../mux-name/mux-name.sh
      ../../modules/shell/zellij.kdl
      ../../modules/shell/zellij-layout-guiom.kdl
    ];
  };
  cargoRoot = "pkgs/reviews";
  buildAndTestSubdir = "pkgs/reviews";
  cargoLock.lockFile = ./Cargo.lock;

  dontCargoBuild = true;
  checkType = "debug";
  useNextest = true;
  cargoTestFlags = [
    "--test"
    "review"
  ];
  # review.sh's own runtime inputs, less what the tests stub (gh, zellij-attach,
  # notify-send, mux-name).
  nativeCheckInputs = [
    zellij
    zellij-sessions
    git
    jq
    gawk
    gnugrep
    util-linux
  ];
  env.WT_BIN = lib.getExe wt;

  installPhase = "touch $out";
}

# The PR picker, and `reviews open`, which opens a PR in zellij. The bar reads it
# through `reviews --json`.
{
  lib,
  rustPlatform,
  makeWrapper,
  gh,
  curl,
  cargoTools,
  zellij,
  zellij-attach,
  zellij-sessions,
  mux-name,
  git,
  wt,
  util-linux,
  libnotify,
}:

rustPlatform.buildRustPackage {
  pname = "reviews";
  version = "0.1.0";
  # wt-core is a path dependency; the tests copy the shell's zellij config and run mux-name.sh.
  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ./src
      ./tests
      ./Cargo.toml
      ./Cargo.lock
      ./.config
      ../wt/crates
      ../wt/Cargo.toml
      ../mux-name/mux-name.sh
      ../../modules/shell/zellij.kdl
      ../../modules/shell/zellij-layout-guiom.kdl
    ];
  };
  cargoRoot = "pkgs/reviews";
  buildAndTestSubdir = "pkgs/reviews";
  cargoLock.lockFile = ./Cargo.lock;

  # tests/review.rs drives `reviews open` against real git, wt and zellij; it stubs
  # gh, zellij-attach, notify-send and mux-name. `script` gives zellij a terminal.
  useNextest = true;
  nativeCheckInputs = [
    zellij
    zellij-sessions
    git
    util-linux
  ];
  env.WT_BIN = lib.getExe wt;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/reviews --prefix PATH : ${
      lib.makeBinPath [
        gh
        curl
        cargoTools.linear
        zellij
        zellij-attach
        zellij-sessions
        mux-name
        git
        wt
        util-linux
        libnotify
      ]
    }
  '';

  meta.mainProgram = "reviews";
}

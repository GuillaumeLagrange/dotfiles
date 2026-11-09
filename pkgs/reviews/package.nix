# The PR picker. The bar reads it through `reviews --json`.
{
  lib,
  rustPlatform,
  makeWrapper,
  gh,
  curl,
  cargoTools,
}:

rustPlatform.buildRustPackage {
  pname = "reviews";
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
    wrapProgram $out/bin/reviews --prefix PATH : ${
      lib.makeBinPath [
        gh
        curl
        cargoTools.linear
      ]
    }
  '';

  meta.mainProgram = "reviews";
}

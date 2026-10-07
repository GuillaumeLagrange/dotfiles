# Underscore-prefixed so import-tree does not treat it as a flake module.
{
  lib,
  rustPlatform,
  makeWrapper,
  gh,
  curl,
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
      ]
    }
  '';

  meta.mainProgram = "reviews";
}

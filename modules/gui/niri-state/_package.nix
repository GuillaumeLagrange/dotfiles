# Underscore-prefixed so import-tree does not treat it as a flake module.
#
# Both bars call this, so they share one build; defining it twice would fork
# into two the moment one copy is edited.
{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "niri-state";
  version = "0.1.0";
  # Docs are excluded so editing them does not rebuild the crate.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./src
      ./Cargo.toml
      ./Cargo.lock
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;
}

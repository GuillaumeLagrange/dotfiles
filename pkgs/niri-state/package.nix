# The niri IPC tap the bar reads its layout model from. See AGENTS.md.
{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "niri-state";
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
}

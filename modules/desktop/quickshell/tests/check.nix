# The bar's tests as a check, against a home's `quickshellTestEnv`. Not a module: the
# desktop group calls it.
{
  lib,
  rustPlatform,
  testEnv,
}:

rustPlatform.buildRustPackage {
  pname = "quickshell-tests";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./src
      ./tests
      ./Cargo.toml
      ./Cargo.lock
      ./.config
      ./test-env.sh
      ./ControlCenterProbe.qml
      ./StartProbe.qml
      ./TestProbe.qml
      ./WorkspacesProbe.qml
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;

  dontCargoBuild = true;
  checkType = "debug";
  useNextest = true;
  env.QUICKSHELL_TEST_ENV = testEnv;

  installPhase = "touch $out";
}

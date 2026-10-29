# Underscore-prefixed so import-tree does not treat it as a flake module.
#
# zellij's own tab-bar, from the source of the zellij in use, with the minimap at its
# right end: `tab-bar.patch` makes it compile ./src as its `minimap` module.
{
  lib,
  buildPackages,
  pkgsCross,
  zellij-unwrapped,
}:
pkgsCross.wasi32.rustPlatform.buildRustPackage {
  pname = "zellij-tab-bar-minimap";
  inherit (zellij-unwrapped) version src cargoDeps;

  patches = [ ./tab-bar.patch ];
  postPatch = ''
    cp -r ${./src} default-plugins/tab-bar/src/minimap
  '';

  # rustc passes lld arguments to the linker nixpkgs sets on cargo's command line, clang,
  # which refuses them. Overridden here since a codegen flag repeated wins the last time.
  env.RUSTFLAGS = "-C linker=${buildPackages.lld}/bin/wasm-ld";

  cargoBuildFlags = [
    "-p"
    "tab-bar"
  ];
  doCheck = false;

  installPhase = ''
    runHook preInstall
    install -Dm444 target/*/release/tab-bar.wasm $out/tab-bar.wasm
    runHook postInstall
  '';

  meta.license = lib.licenses.mit;
}

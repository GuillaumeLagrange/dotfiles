# The tools the Justfile, the pre-commit hooks and the tests call, entered by .envrc and by
# CI. One shell for both, so a test drives the same programs here and on gullywash's runner,
# which has none of what a home installs. A test without its program skips itself, which CI
# would not notice. Rust is nixpkgs-unstable's, the one the packages of pkgs/ build with.
{
  perSystem =
    { pkgs, ... }:
    {
      # mkShell: its C toolchain links the crates and builds their build scripts' C.
      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          just
          unstable.prek
          nixfmt
          stylua
          ruff
          shfmt
          # qmlformat
          qt6.qtdeclarative
          biome
          unstable.cargo
          unstable.rustc
          unstable.clippy
          unstable.rustfmt
          unstable.rust-analyzer
          unstable.cargo-nextest
          # Not stable's 1.15: it cannot read crates.io versions off fetchCrate's static.crates.io URLs
          unstable.nix-update
          # The zellij the homes and the packages run.
          unstable.zellij
          # script
          util-linux
          jq
          gawk
          gnugrep
          git
          direnv
          nodejs
        ];
        RUST_SRC_PATH = pkgs.unstable.rustPlatform.rustLibSrc;
      };
    };
}

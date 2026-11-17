# The tools the Justfile and the pre-commit hooks call, entered by .envrc. Rust is
# nixpkgs-unstable's, the one the packages of pkgs/ build with.
{
  perSystem =
    { pkgs, config, ... }:
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
        ];
        RUST_SRC_PATH = pkgs.unstable.rustPlatform.rustLibSrc;
      };

      # `just test` on gullywash's CI runner, which has none of what a home installs: every
      # program a test drives. A test without its program skips itself, which CI would not notice.
      devShells.ci = pkgs.mkShell {
        inputsFrom = [ config.devShells.default ];
        packages = with pkgs; [
          # The zellij the homes and the packages run.
          unstable.zellij
          # script
          util-linux
          # pgrep
          procps
          jq
          gawk
          gnugrep
          git
          direnv
          nodejs
        ];
      };
    };
}

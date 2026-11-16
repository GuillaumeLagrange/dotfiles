# The tools the Justfile and the pre-commit hooks call, entered by .envrc. Rust comes
# from rustup, which every home installs, at the version rust-toolchain.toml pins.
{
  perSystem =
    { pkgs, config, ... }:
    {
      devShells.default = pkgs.mkShellNoCC {
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
          unstable.cargo-nextest
          # Not stable's 1.15: it cannot read crates.io versions off fetchCrate's static.crates.io URLs
          unstable.nix-update
        ];
      };

      # `just test` on gullywash's CI runner, which has none of what a home installs: rustup and
      # a C toolchain to link with, and every program a test drives. A test without its program
      # skips itself, which CI would not notice.
      devShells.ci = pkgs.mkShell {
        inputsFrom = [ config.devShells.default ];
        packages = with pkgs; [
          rustup
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

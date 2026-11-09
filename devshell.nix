# The tools the Justfile and the pre-commit hooks call, entered by .envrc. Rust comes
# from rustup, which every home installs.
{
  perSystem =
    { pkgs, ... }:
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
    };
}

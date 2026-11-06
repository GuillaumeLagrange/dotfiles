# Tools nixpkgs lacks that I would otherwise `cargo install`: one `_<name>.nix` each.
# `just bump [NAME]` moves them to their latest release. Exposed as `pkgs.cargoTools.<name>`
# and `.#<name>`.
{ lib, ... }:
let
  names = lib.pipe (builtins.readDir ./.) [
    builtins.attrNames
    (lib.filter (f: lib.hasPrefix "_" f && lib.hasSuffix ".nix" f))
    (map (f: lib.removeSuffix ".nix" (lib.removePrefix "_" f)))
  ];
in
{
  perSystem =
    { pkgs, config, ... }:
    {
      packages = lib.genAttrs names (name: pkgs.callPackage ./_${name}.nix { });
      overlayAttrs.cargoTools = lib.getAttrs names config.packages;
    };
}

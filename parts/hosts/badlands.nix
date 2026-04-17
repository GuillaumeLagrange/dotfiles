{
  inputs,
  withSystem,
  mkHomeManagerModule,
  ...
}:
{
  flake.nixosConfigurations.badlands = withSystem "x86_64-linux" (
    { pkgs-unstable, ... }:
    import ../../hosts/badlands/default.nix {
      inherit inputs;
      mkHomeManagerModule = mkHomeManagerModule { inherit pkgs-unstable; };
    }
  );
}

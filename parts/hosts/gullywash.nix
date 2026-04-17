{
  inputs,
  withSystem,
  mkHomeManagerModule,
  sshPublicKey,
  ...
}:
{
  flake.nixosConfigurations.gullywash = withSystem "x86_64-linux" (
    { pkgs-unstable, ... }:
    import ../../hosts/gullywash/default.nix {
      inherit inputs sshPublicKey;
      mkHomeManagerModule = mkHomeManagerModule { inherit pkgs-unstable; };
    }
  );
}

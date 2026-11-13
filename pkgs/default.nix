# The programs this repo builds, and the overlay that makes each `pkgs.<name>` in
# every host and home. `nix build .#<name>` builds one.
{ inputs, self, ... }:
{
  flake.overlays.default = final: prev: {
    unstable = import inputs.nixpkgs-unstable {
      inherit (final.stdenv.hostPlatform) system;
      config.allowUnfree = true;
      overlays = [
        inputs.quickshell.overlays.default
        # Virtual sinks and sources are devices too: see virtual-devices.patch. The
        # package is a wrapper copying `unwrapped`, so the copy is pointed at the patched build.
        (_: qs: {
          quickshell =
            let
              unwrapped = qs.quickshell.unwrapped.overrideAttrs (old: {
                patches = (old.patches or [ ]) ++ [ ./quickshell/virtual-devices.patch ];
              });
            in
            qs.quickshell.overrideAttrs (old: {
              installPhase = ''
                mkdir -p $out
                cp -r ${unwrapped}/* $out
              '';
              passthru = old.passthru // {
                inherit unwrapped;
              };
            });
        })
      ];
    };

    # Hot-corner delay and barrier, middle click closes in the overview: see mouse.patch.
    niri = prev.niri.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./niri/mouse.patch ];
    });

    # Rust CLIs nixpkgs lacks. `just bump` moves them to their latest release.
    cargoTools.linear = final.callPackage ./cargo-tools/linear.nix { };

    mux-name = final.callPackage ./mux-name/package.nix { };
    niri-displays = final.callPackage ./niri-displays/package.nix { };
    niri-state = final.callPackage ./niri-state/package.nix { };
    niri-workspaces = final.callPackage ./niri-workspaces/package.nix { };
    omp-panel = final.callPackage ./omp-panel/package.nix { zellij = final.unstable.zellij; };
    passwords = final.callPackage ./passwords/package.nix {
      inherit (final.unstable) proton-pass-cli vicinae;
    };
    review = final.callPackage ./reviews/review.nix { zellij = final.unstable.zellij; };
    reviews = final.callPackage ./reviews/package.nix { };
    wt = final.callPackage ./wt/package.nix { zellij = final.unstable.zellij; };
    zellij-attach = final.callPackage ./zellij-attach/package.nix { zellij = final.unstable.zellij; };
  };

  perSystem =
    { system, pkgs, ... }:
    {
      _module.args.pkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [ self.overlays.default ];
      };

      packages = {
        inherit (pkgs)
          mux-name
          niri-displays
          niri-state
          niri-workspaces
          omp-panel
          passwords
          review
          reviews
          wt
          zellij-attach
          ;
        inherit (pkgs.cargoTools) linear;
      };
    };
}

# The programs this repo builds, and the overlay that makes each `pkgs.<name>` in
# every host and home. `nix build .#<name>` builds one.
{ inputs, self, ... }:
{
  flake.overlays.default =
    final: prev:
    let
      # The Rust of the devshell, where the crates' tests and clippy run.
      rust = { inherit (final.unstable) rustPlatform; };
    in
    {
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

      # One patch per feature, in the order they apply.
      niri = prev.niri.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ./niri/hot-corner-delay.patch # hot-corners { delay-ms }
          ./niri/hot-corner-barrier.patch # hot-corners { barrier; barrier-corners }
          ./niri/overview-middle-click-close.patch # middle click closes a window in the overview
          ./niri/window-preview.patch # `WindowPreview` IPC request, for the bar's workspace map
          ./niri/overview-labels.patch # app icon and title on each tile in the overview
        ];
      });

      # Rust CLIs nixpkgs lacks. `just bump` moves them to their latest release.
      cargoTools.linear = final.callPackage ./cargo-tools/linear.nix { };

      mux-name = final.callPackage ./mux-name/package.nix { };
      niri-displays = final.callPackage ./niri-displays/package.nix { };
      niri-state = final.callPackage ./niri-state/package.nix rust;
      niri-workspaces = final.callPackage ./niri-workspaces/package.nix { };
      omp-panel = final.callPackage ./omp-panel/package.nix (rust // { zellij = final.unstable.zellij; });
      review = final.callPackage ./reviews/review.nix { zellij = final.unstable.zellij; };
      reviews = final.callPackage ./reviews/package.nix rust;
      wt = final.callPackage ./wt/package.nix (rust // { zellij = final.unstable.zellij; });
      zellij-attach = final.callPackage ./zellij-attach/package.nix { zellij = final.unstable.zellij; };
      zellij-sessions = final.callPackage ./zellij-sessions/package.nix (
        rust // { zellij = final.unstable.zellij; }
      );
    };

  perSystem =
    {
      system,
      pkgs,
      self',
      ...
    }:
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
          review
          reviews
          wt
          zellij-attach
          zellij-sessions
          ;
        inherit (pkgs.cargoTools) linear;
      };

      # The packages run their tests in their builds; review.sh's need a build of their own.
      checks = self'.packages // {
        review = pkgs.callPackage ./reviews/review-tests.nix {
          inherit (pkgs.unstable) rustPlatform zellij;
        };
      };
    };
}

# The programs this repo builds, and the overlay that makes each `pkgs.<name>` in
# every host and home. `nix build .#<name>` builds one.
{ inputs, self, ... }:
{
  flake.overlays.default = final: prev: {
    unstable = import inputs.nixpkgs-unstable {
      inherit (final.stdenv.hostPlatform) system;
      config.allowUnfree = true;
      overlays = [ inputs.quickshell.overlays.default ];
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
          review
          reviews
          wt
          zellij-attach
          ;
        inherit (pkgs.cargoTools) linear;
      };
    };
}

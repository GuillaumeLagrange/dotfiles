{ self, ... }:
{
  flake.modules.nixos.codspeed = {
    imports = [ ./_oneleet.nix ];

    programs._1password.enable = true;
    programs._1password-gui = {
      enable = true;
      polkitPolicyOwners = [ "guillaume" ];
    };

    programs.oneleet.enable = true;
  };

  # Terminal-only tooling, usable on any host (mac mini, remote boxes, ...).
  flake.modules.homeManager.codspeed-headless =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    let
      codspeed_root = "${config.home.homeDirectory}/codspeed";
      vgbasedir = "\${WORKSPACE_ROOT:-${codspeed_root}}/valgrind-codspeed";

      # `cargo install` a crate of <repo>, resolved against the current workspace
      # root and run under that repo's direnv environment.
      cargoInstall =
        name: repo: path:
        pkgs.writeShellScriptBin name ''
          dir="''${WORKSPACE_ROOT:-${codspeed_root}}/${repo}"
          cd "$dir" || exit 1
          exec direnv exec "$dir" cargo install --path ${path} --locked
        '';
    in
    {
      programs.granted.enable = true;

      programs.git = {
        settings = {
          diff.lfstext.textconv = "cat";
        };
      };

      home.shellAliases = {
        ct = "cargo nextest run";
        mj = "make -j";
        m = "make";
        cm = "cmake ..";
        bazel = "bazelisk";
        cdtmp = "cd $(ls -td /tmp/profile.*.out | head -n 1)";
        turbo = "pnpm turbo";
        codstaging = "export CODSPEED_PROFILE=staging";
        coddev = "export CODSPEED_PROFILE=dev";
        codprod = "unset CODSPEED_PROFILE";
      };

      home.sessionVariables = {
        CODSPEED_ROOT = codspeed_root;
        # `cdr` and anything else keyed on the workspace root land in ~/codspeed
        WORKSPACE_ROOT = codspeed_root;
      };

      home.packages =
        with pkgs;
        [
          awscli2
          pkgs.unstable.uv
        ]
        ++ lib.optionals stdenv.isLinux [
          (writeShellScriptBin "valgrind" ''
            RUSTUP_FORCE_ARG0=cargo exec "${vgbasedir}/vg-in-place" "$@"
          '')
        ]
        ++ [
          (cargoInstall "cicc" "codspeed-rust" "./crates/cargo-codspeed")
          (cargoInstall "cicr" "codspeed" ".")
          (cargoInstall "cieh" "codspeed" "./crates/exec-harness")
          (cargoInstall "cicm" "codspeed" "./crates/memtrack")

          (writeShellScriptBin "local_run_helper" ''
            archive_name="''${1:-sample.tar.gz}"
            runner_profile_dir=$(ls -td /tmp/profile.*.out | head -n 1)
            tar -czf "$archive_name" -C "$runner_profile_dir" .
          '')
        ];
    };

  # Desktop additions on top of the headless tooling.
  flake.modules.homeManager.codspeed =
    { pkgs, ... }:
    {
      imports = [ self.modules.homeManager.codspeed-headless ];

      programs.ssh = {
        settings = {
          "codspeeds-mac-mini*" = {
            ForwardAgent = true;
            User = "codspeed";
            RemoteForward = [
              {
                host.address = "/run/user/1000/gnupg/S.gpg-agent.extra";
                bind.address = "/Users/codspeed/.gnupg/S.gpg-agent";
              }
            ];
          };
        };
      };

      home.packages = with pkgs; [
        kdePackages.kcachegrind
        dbeaver-bin
      ];
    };
}

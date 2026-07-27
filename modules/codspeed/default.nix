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
      vgbasedir = "${codspeed_root}/valgrind-codspeed";
    in
    {
      programs.zsh.initContent = ''
        # Easy navigation in the codspeed repositories
        cdc() {
          cd "${codspeed_root}/$@"
        }
        compdef '_files -W "${codspeed_root}" -/' cdc
      '';

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
          (writeShellScriptBin "cicc" ''
            direnv exec ${codspeed_root}/codspeed-rust bash -c 'cd ${codspeed_root}/codspeed-rust && cargo install --path ./crates/cargo-codspeed --locked'
          '')

          (writeShellScriptBin "cicr" ''
            direnv exec ${codspeed_root}/codspeed bash -c 'cd ${codspeed_root}/codspeed && cargo install --path . --locked'
          '')

          (writeShellScriptBin "cieh" ''
            direnv exec ${codspeed_root}/codspeed bash -c 'cd ${codspeed_root}/codspeed && cargo install --path ./crates/exec-harness --locked'
          '')

          (writeShellScriptBin "cicm" ''
            direnv exec ${codspeed_root}/codspeed bash -c 'cd ${codspeed_root}/codspeed && cargo install --path ./crates/memtrack --locked'
          '')

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

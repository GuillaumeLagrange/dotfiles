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

  flake.modules.homeManager.codspeed =
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

        # cod: wrapper that evals the script output for env commands
        cod() {
          case "$1" in
            setup) command cod "$@" ;;
            *)     eval "$(command cod "$@")" ;;
          esac
        }
      '';

      programs.granted.enable = true;

      programs.git = {
        settings = {
          diff.lfstext.textconv = "cat";
        };
      };

      home.shellAliases = {
        cs = "codspeed";
        mj = "make -j";
        m = "make";
        cm = "cmake ..";
        bazel = "bazelisk";
        cdtmp = "cd $(ls -td /tmp/profile.*.out | head -n 1)";
        turbo = "pnpm turbo";
      };

      xdg.desktopEntries = lib.mkIf pkgs.stdenv.isLinux {
        mongodb-compass = {
          name = "MongoDB Compass";
          comment = "The MongoDB GUI";
          genericName = "MongoDB Compass";
          exec = "mongodb-compass --password-store=\"gnome-libsecret\" --ignore-additional-command-line-flags";
          icon = "mongodb-compass";
          categories = [
            "GNOME"
            "GTK"
            "Utility"
          ];
          mimeType = [
            "x-scheme-handler/mongodb"
            "x-scheme-handler/mongodb+srv"
          ];
          startupNotify = true;
        };
      };

      programs.ssh = {
        matchBlocks = {
          "codspeeds-mac-mini*" = {
            forwardAgent = true;
            user = "codspeed";
            remoteForwards = [
              {
                host.address = "/run/user/1000/gnupg/S.gpg-agent.extra";
                bind.address = "/Users/codspeed/.gnupg/S.gpg-agent";
              }
            ];
          };
        };
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
          mongodb-compass
          mongodb-tools
          kdePackages.kcachegrind

          (writeShellScriptBin "valgrind" ''
            VALGRIND_LIB="${vgbasedir}/.in_place" \
            VALGRIND_LIB_INNER="${vgbasedir}/.in_place" \
            RUSTUP_FORCE_ARG0=cargo \
            exec "${vgbasedir}/coregrind/valgrind" "$@"
          '')
        ]
        ++ [
          (writeShellScriptBin "cicc" ''
            direnv exec ${codspeed_root}/rust bash -c 'cd ${codspeed_root}/rust && cargo install --path ./crates/cargo-codspeed --locked'
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

          (writeShellScriptBin "cod" (builtins.readFile ./cod.sh))
        ];
    };
}

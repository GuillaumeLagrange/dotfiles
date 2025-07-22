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
  options = {
    codspeed.enable = lib.mkEnableOption "codspeed specific tools";
  };

  config = lib.mkIf config.codspeed.enable {
    programs.zsh.initContent = ''
      # Easy navigation in the codspeed repositories
      cdc() {
        cd "${codspeed_root}/$@"
      }
      compdef '_files -W "${codspeed_root}" -/' cdc
    '';

    programs.granted.enable = true;

    programs.git = {
      extraConfig = {
        diff.lfstext.textconv = "cat";
      };
    };

    home.shellAliases = {
      wt = "export CODSPEED_RUNNER_MODE=walltime";
      instr = "export CODSPEED_RUNNER_MODE=instrumentation";
      mj = "make -j";
      m = "make";
      cm = "cmake ..";
      bazel = "bazelisk";
      # Go to the latest directory of the codspeed runner
      cdtmp = "cd $(ls -td /tmp/profile.*.out | head -n 1)";
      codlocal = "export CODSPEED_API_URL=$CODSPEED_API_URL_LOCAL && export CODSPEED_UPLOAD_URL=$CODSPEED_UPLOAD_URL_LOCAL";
      codstaging = "export CODSPEED_API_URL=$CODSPEED_API_URL_STAGING && export CODSPEED_UPLOAD_URL=$CODSPEED_UPLOAD_URL_STAGING";
      codprod = "unset CODSPEED_API_URL && unset CODSPEED_UPLOAD_URL";
      moon = "pnpm moon";

    };
    home.sessionVariables = {
      CODSPEED_API_URL_LOCAL = "https://z7worpfffi.execute-api.eu-west-1.amazonaws.com/dev/";
      CODSPEED_UPLOAD_URL_LOCAL = "https://vpskktkxa2.execute-api.eu-west-1.amazonaws.com/upload";

      CODSPEED_API_URL_STAGING = "https://gql.staging.preview.codspeed.io/";
      CODSPEED_UPLOAD_URL_STAGING = "https://api.staging.preview.codspeed.io/upload";
    };

    xdg.desktopEntries = {
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

    home.packages = with pkgs; [
      awscli2
      mongodb-compass
      mongodb-tools
      uv
      kdePackages.kcachegrind

      (writeShellScriptBin "valgrind" ''
        VALGRIND_LIB="${vgbasedir}/.in_place" \
        VALGRIND_LIB_INNER="${vgbasedir}/.in_place" \
        RUSTUP_FORCE_ARG0=cargo \
        exec "${vgbasedir}/coregrind/valgrind" "$@"
      '')

      # Cargo install cargo-codspeed
      (writeShellScriptBin "cicc" ''
        cd ${codspeed_root}/rust && cargo install --path ./crates/cargo-codspeed --locked
      '')

      # Cargo install codspeed runner
      (writeShellScriptBin "cicr" ''
        cd ${codspeed_root}/runner && cargo install --path . --locked
      '')
    ];
  };
}

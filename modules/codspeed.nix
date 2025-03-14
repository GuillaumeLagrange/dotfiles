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
    programs.zsh.initExtra = ''
      # Easy navigation in the codspeed repositories
      cdc() {
        cd "${codspeed_root}/$@"
      }
      compdef '_files -W "${codspeed_root}" -/' cdc

      docker-cargo() {
        if [ "$#" -lt 2 ]; then
          echo "Usage: docker-cargo <docker-image> <cargo-command> [additional-args...]"
          return 1
        fi

        local image="$1"
        shift
        local cargo_command="$@"

        docker run --rm -it \
          -u $(id -u):$(id -g) \
          -v "$(pwd)":/home/src \
          -v "$HOME/.cargo/registry":/home/src/.cargo/registry \
          -v "$HOME/.cargo/git":/home/src/.cargo/git \
          -e CARGO_HOME=/home/src/.cargo \
          "$image" \
          sh -c "$cargo_command"
      }
    '';

    programs.granted.enable = true;

    home.shellAliases = {
      wt = "export CODSPEED_RUNNER_MODE=walltime";
      instr = "export CODSPEED_RUNNER_MODE=instrumentation";
      mj = "make -j";
      m = "make";
      cm = "cmake ..";
    };

    home.packages = with pkgs; [
      awscli2

      (writeShellScriptBin "valgrind" ''
        VALGRIND_LIB="${vgbasedir}/.in_place" \
        VALGRIND_LIB_INNER="${vgbasedir}/.in_place" \
        RUSTUP_FORCE_ARG0=cargo \
        exec "${vgbasedir}/coregrind/valgrind" "$@"
      '')

    ];
  };
}

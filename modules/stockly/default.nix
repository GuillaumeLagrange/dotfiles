{
  pkgs,
  lib,
  config,
  pkgs-datagrip,
  ...
}:
let
  stockly_main = "${config.home.homeDirectory}/stockly/Main";
in
{
  options = {
    stockly.enable = lib.mkEnableOption "stockly specific tools";
  };

  config = lib.mkIf config.stockly.enable {
    programs.zsh = {
      initExtra = ''
        # Path to where the Stockly git repository is cloned on this computer
        export STOCKLY_MAIN=${stockly_main}

        # Stockly CLI quick access
        s() {
          cargo run --manifest-path "$STOCKLY_MAIN/.cargo/workspace/Cargo.toml" -p "stockly_cli" --release -- "$@"
        }

        # Run the Stockly Continuous Deployment Makefile
        smake() {
          if [ -d "./StocklyContinuousDeployment" ]; then
            make -C './StocklyContinuousDeployment' $@
          else
            make -C './scd' $@
          fi
        }

        # Easy navigation in the Stockly Main repository
        cdr() {
          cd "$STOCKLY_MAIN/$@"
        }
        compdef '_files -W "$STOCKLY_MAIN" -/' cdr

        # Test & format workspace
        tfw() {
          cdr .cargo/workspace && \
          cargo test --jobs 20 && \
          cargo fmt -- --config "comment_width=120,condense_wildcard_suffixes=false,format_code_in_doc_comments=true,format_macro_bodies=true,hex_literal_case=Upper,imports_granularity=One,normalize_doc_attributes=true,wrap_comments=true" && \
          cargo machete && \
          cd -
        }

        # Format workspace (faster than tfw)
        fw() {
          cdr .cargo/workspace && \
          cargo fmt -- --config "comment_width=120,condense_wildcard_suffixes=false,format_code_in_doc_comments=true,format_macro_bodies=true,hex_literal_case=Upper,imports_granularity=One,normalize_doc_attributes=true,wrap_comments=true" && \
          cargo machete && \
          cd -
        }

        function review() {
          if [ -z "$1" ]; then
              echo "Usage: review <prefix>"
              return 1
          fi

          git fetch --all

          local branch_name
          branch_name=$(git branch --list --remote "*/$1-*" | head -n 1 | sed 's/^\* //;s/ //g;s|^[^/]*/||')

          if [ -z "$branch_name" ]; then
              echo "No branch found matching pattern: $1-*"
              return 1
          fi

          git switch "$branch_name" && git pull && git merge origin/master && git push
        }
      '';
    };

    home.sessionVariables.WLR_DRM_DEVICES = "/dev/dri/card1";

    home.packages = [
      # pkgs-datagrip.jetbrains.datagrip

      (pkgs.writeShellScriptBin "reset_jetbrain_trail.sh" ''
        for product in DataGrip; do
          rm -rf ${config.xdg.configHome}/$product*/eval 2> /dev/null
          rm -rf ${config.xdg.configHome}/JetBrains/$product*/eval 2> /dev/null
        done
        echo "You're good to go!"
      '')

      (pkgs.callPackage ./insomnia.nix { })
      (pkgs.callPackage ./monster.nix { inherit lib; })
    ];
  };
}

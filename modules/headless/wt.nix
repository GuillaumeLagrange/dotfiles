{ ... }:
{
  flake.modules.homeManager.wt =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    let
      cfg = config.programs.wt;

      # Everything wt shells out to has to be listed here: it runs from
      # non-interactive contexts too, with none of a login shell's PATH.
      runtimeInputs = [
        pkgs.coreutils # cp --reflink, df
        pkgs.direnv
        pkgs.fzf
        pkgs.git
        pkgs.zellij
      ]
      ++ cfg.extraRuntimeInputs;

      wt = pkgs.rustPlatform.buildRustPackage {
        pname = "wt";
        version = "0.1.0";

        src = ../../wt;
        cargoLock.lockFile = ../../wt/Cargo.lock;

        nativeBuildInputs = [
          pkgs.installShellFiles
          pkgs.makeWrapper
        ];
        postInstall = ''
          wrapProgram $out/bin/wt --prefix PATH : ${lib.makeBinPath runtimeInputs}
          # A shim that asks the binary for candidates, so completing a session id
          # lists the sessions that exist when you press tab.
          installShellCompletion --cmd wt --zsh <(COMPLETE=zsh $out/bin/wt)
        '';

        meta = {
          description = "Feature-scoped multi-repo workspaces";
          mainProgram = "wt";
        };
      };
    in
    {
      options.programs.wt = {
        extraRuntimeInputs = lib.mkOption {
          type = with lib.types; listOf package;
          default = [ ];
          description = "Extra packages on wt's own PATH.";
        };

      };

      # wt is workspace-agnostic and reads ~/.config/wt/config.toml, which is
      # maintained by hand: naming the repos it may touch describes a codebase, and
      # this repository is public.
      config.home.packages = [ wt ];
    };
}

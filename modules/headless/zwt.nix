{ ... }:
{
  flake.modules.homeManager.zwt =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    let
      cfg = config.programs.zwt;

      # Everything zwt shells out to has to be listed here: it runs from
      # non-interactive contexts too, with none of a login shell's PATH.
      runtimeInputs = [
        pkgs.coreutils # cp --reflink, df
        pkgs.direnv
        pkgs.fzf
        pkgs.git
      ]
      ++ cfg.extraRuntimeInputs;

      zwt = pkgs.rustPlatform.buildRustPackage {
        pname = "zwt";
        version = "0.1.0";

        src = ../../zwt;
        cargoLock.lockFile = ../../zwt/Cargo.lock;

        nativeBuildInputs = [
          pkgs.installShellFiles
          pkgs.makeWrapper
        ];
        postInstall = ''
          wrapProgram $out/bin/zwt --prefix PATH : ${lib.makeBinPath runtimeInputs}
          # A shim that asks the binary for candidates, so completing a session id
          # lists the sessions that exist when you press tab.
          installShellCompletion --cmd zwt --zsh <(COMPLETE=zsh $out/bin/zwt)
        '';

        meta = {
          description = "Feature-scoped multi-repo workspaces";
          mainProgram = "zwt";
        };
      };
    in
    {
      options.programs.zwt = {
        extraRuntimeInputs = lib.mkOption {
          type = with lib.types; listOf package;
          default = [ ];
          description = "Extra packages on zwt's own PATH.";
        };

      };

      # zwt is workspace-agnostic and reads ~/.config/zwt/config.toml, which is
      # maintained by hand: naming the repos it may touch describes a codebase, and
      # this repository is public.
      config.home.packages = [ zwt ];
    };
}

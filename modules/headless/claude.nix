{ ... }:
{
  flake.modules.homeManager.claude =
    { config, ... }:
    let
      claudeDir = "${config.home.homeDirectory}/dotfiles/claude";
    in
    {
      # Managed out-of-store so Claude Code can keep rewriting settings.json and
      # the tracked files stay editable without a rebuild — mirrors how nvim is
      # symlinked from the repo.
      #
      # The whole skills dir is symlinked, so a skill is added by dropping a
      # folder into claude/skills. Private skills live there too but are
      # gitignored (claude/skills/.gitignore) — present locally, never committed.
      # The caveman skill doubles as an always-on mode: a SessionStart hook in
      # settings.json injects its body every session.
      home.file = {
        ".claude/settings.json".source =
          config.lib.file.mkOutOfStoreSymlink "${claudeDir}/settings.json";

        ".claude/skills".source =
          config.lib.file.mkOutOfStoreSymlink "${claudeDir}/skills";
      };
    };
}

{ ... }:
{
  flake.modules.homeManager.pi =
    { config, ... }:
    let
      piDir = "${config.home.homeDirectory}/dotfiles/pi";
    in
    {
      # pi (@earendil-works/pi-coding-agent) is installed out-of-band via pnpm,
      # so we only manage its config here. Like claude/settings.json, pi keeps
      # rewriting agent/settings.json (lastChangelogVersion, `pi install`,
      # `pi config`, ...), so it is symlinked out-of-store to stay writable
      # without a rebuild and editable in the repo.
      #
      # Skills are shared with Claude Code: settings.json points `skills` at
      # ~/.claude/skills (managed by modules/headless/claude.nix), so a single
      # source of truth in claude/skills serves both harnesses.
      #
      # The extensions dir is symlinked whole (like claude/skills) so pi
      # auto-discovers them and `/reload` works. caveman-mode.ts makes the
      # shared caveman skill always-on, mirroring the Claude Code SessionStart
      # hook.
      #
      # Secrets (~/.pi/agent/auth.json) are written by pi itself and are NOT
      # tracked here.
      home.file = {
        ".pi/agent/settings.json".source =
          config.lib.file.mkOutOfStoreSymlink "${piDir}/settings.json";

        ".pi/agent/extensions".source =
          config.lib.file.mkOutOfStoreSymlink "${piDir}/extensions";
      };
    };
}

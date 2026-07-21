{ ... }:
{
  flake.modules.homeManager.claude =
    { config, lib, ... }:
    let
      claudeDir = "${config.home.homeDirectory}/dotfiles/claude";
    in
    {
      # Every ~/.claude entry is linked to the dotfiles repo by an activation
      # script rather than home.file/mkOutOfStoreSymlink. mkOutOfStoreSymlink
      # places the symlink node itself under /nix/store, so a program doing an
      # atomic write (temp file in the target's directory, then rename) resolves
      # a single hop to /nix/store and fails with EROFS. Claude Code rewrites
      # settings.json that way. A direct ln -sf points at the writable dotfile,
      # whose directory is writable, so the temp file lands correctly.
      #
      # The whole skills dir is linked, so a skill is added by dropping a folder
      # into claude/skills. Private skills live there too but are gitignored
      # (claude/skills/.gitignore) — present locally, never committed. The
      # caveman skill doubles as an always-on mode: a SessionStart hook in
      # settings.json injects its body every session.
      #
      # settings.local.json holds machine-local overrides (work marketplace
      # paths, etc.) and is gitignored, so its source may be absent on a fresh
      # checkout and appear later; the activation script re-links it on every
      # switch, unconditional once the source exists.
      home.activation.claudeLinks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run mkdir -p "${config.home.homeDirectory}/.claude"
        run ln -sfn "${claudeDir}/settings.json" "${config.home.homeDirectory}/.claude/settings.json"
        run ln -sfn "${claudeDir}/skills" "${config.home.homeDirectory}/.claude/skills"
        if [ -e "${claudeDir}/settings.local.json" ]; then
          run ln -sf "${claudeDir}/settings.local.json" "${config.home.homeDirectory}/.claude/settings.local.json"
        fi
      '';
    };
}

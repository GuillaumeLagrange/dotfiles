{ ... }:
{
  flake.modules.homeManager.ai =
    { config, lib, ... }:
    let
      aiDir = "${config.home.homeDirectory}/dotfiles/ai";
      claudeHome = "${config.home.homeDirectory}/.claude";
      ompAgentDir = "${config.home.homeDirectory}/.omp/agent";
      agentUserDir = "${config.home.homeDirectory}/.agent";
    in
    {
      # Plain `ln -sf` rather than home.file/mkOutOfStoreSymlink: the latter
      # puts the symlink node itself under /nix/store, so an atomic write
      # (temp file next to the target, then rename) lands in the store and
      # fails with EROFS. Claude Code rewrites settings.json that way.
      #
      # omp's config.yml is not linked: it is loaded read-only through
      # PI_CONFIG_FILES (below), and omp writes its own changes to
      # ~/.omp/agent/config.yml, which stays local.
      #
      # Only declarative files are linked; the rest of ~/.omp/agent is state
      # (auth, history, models, blobs, sessions) and stays untracked.
      #
      # settings.local.json holds machine-local claude overrides and is
      # gitignored, so it may be absent on a fresh checkout and appear later.
      # ai/private is a separate, gitignored private repo of rules too
      # work-specific to publish, and may not be cloned. ~/.omp/agent/rules
      # points into this tracked repo, so its rules go to ~/.agent/rules, which
      # omp also reads.
      home.activation.aiLinks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run mkdir -p "${claudeHome}" "${ompAgentDir}"

        run ln -sfn "${aiDir}/claude/settings.json" "${claudeHome}/settings.json"
        # Both agents create these dirs themselves; ln -sfn cannot replace a
        # real directory, so drop it first.
        if [ -d "${claudeHome}/skills" ] && [ ! -L "${claudeHome}/skills" ]; then
          run rm -rf "${claudeHome}/skills"
        fi
        run ln -sfn "${aiDir}/skills" "${claudeHome}/skills"
        if [ -e "${aiDir}/claude/settings.local.json" ]; then
          run ln -sf "${aiDir}/claude/settings.local.json" "${claudeHome}/settings.local.json"
        fi

        # Write a real file over the symlink rather than just deleting it: if
        # config.yml is missing, omp rebuilds it from legacy agent.db settings.
        if [ -L "${ompAgentDir}/config.yml" ]; then
          run rm "${ompAgentDir}/config.yml"
          run sh -c 'echo "hideThinkingBlock: true" > "$1"' _ "${ompAgentDir}/config.yml"
        fi
        run ln -sfn "${aiDir}/omp/mcp.json" "${ompAgentDir}/mcp.json"
        if [ -d "${ompAgentDir}/rules" ] && [ ! -L "${ompAgentDir}/rules" ]; then
          run rm -rf "${ompAgentDir}/rules"
        fi
        run ln -sfn "${aiDir}/omp/rules" "${ompAgentDir}/rules"
        if [ -d "${ompAgentDir}/extensions" ] && [ ! -L "${ompAgentDir}/extensions" ]; then
          run rm -rf "${ompAgentDir}/extensions"
        fi
        run ln -sfn "${aiDir}/omp/extensions" "${ompAgentDir}/extensions"
        if [ -d "${ompAgentDir}/skills" ] && [ ! -L "${ompAgentDir}/skills" ]; then
          run rm -rf "${ompAgentDir}/skills"
        fi
        run ln -sfn "${aiDir}/skills" "${ompAgentDir}/skills"

        # Not ~/.agents: on some machines it is a symlink into a work checkout.
        # Skip ~/.agent too if it is a symlink, so nothing lands in a directory
        # this config does not own.
        if [ -d "${aiDir}/private/rules" ] && [ ! -L "${agentUserDir}" ]; then
          run mkdir -p "${agentUserDir}"
          run ln -sfn "${aiDir}/private/rules" "${agentUserDir}/rules"
        fi
      '';

      home.sessionVariables.PI_CONFIG_FILES = "${aiDir}/omp/config.yml";
    };
}

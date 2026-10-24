{ ... }:
{
  flake.modules.homeManager.ai =
    { config, lib, ... }:
    let
      aiDir = "${config.home.homeDirectory}/dotfiles/ai";
      ompAgentDir = "${config.home.homeDirectory}/.omp/agent";
    in
    {
      # omp's config.yml is not linked: it is loaded read-only through
      # PI_CONFIG_FILES (below), and omp writes its own changes to
      # ~/.omp/agent/config.yml, which stays local. Skills that must not be
      # committed here (work, private) are registered there per machine with
      # `skills.customDirectories`; ai/omp/config.yml must not set that key,
      # or it shadows the local list.
      home.activation.aiLinks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run mkdir -p "${ompAgentDir}"
        run ln -sfn "${aiDir}/omp/mcp.json" "${ompAgentDir}/mcp.json"
        # omp creates these dirs itself; ln -sfn cannot replace a real
        # directory, so drop it first.
        for d in rules extensions skills; do
          if [ -d "${ompAgentDir}/$d" ] && [ ! -L "${ompAgentDir}/$d" ]; then
            run rm -rf "${ompAgentDir}/$d"
          fi
          run ln -sfn "${aiDir}/omp/$d" "${ompAgentDir}/$d"
        done
      '';

      home.sessionVariables.PI_CONFIG_FILES = "${aiDir}/omp/config.yml";
      # zellij drops kitty unicode placeholders but shows direct placements:
      # https://github.com/zellij-org/zellij/issues/5530 (fix: PR #5531).
      home.sessionVariables.PI_NO_KITTY_PLACEHOLDERS = "1";
    };
}

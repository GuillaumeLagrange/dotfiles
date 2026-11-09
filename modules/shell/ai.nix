{ config, lib, ... }:
let
  aiDir = "${config.home.homeDirectory}/dotfiles/ai";
  ompAgentDir = "${config.home.homeDirectory}/.omp/agent";
in
{
  _class = "homeManager";

  # config.yml is read through PI_CONFIG_FILES, not linked: omp writes its own
  # ~/.omp/agent/config.yml. mcp.json holds work servers, linked by the work group.
  home.activation.aiLinks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p "${ompAgentDir}"
    if [ -L "${ompAgentDir}/mcp.json" ]; then
      run rm "${ompAgentDir}/mcp.json"
    fi
    for d in rules extensions skills; do
      if [ -d "${ompAgentDir}/$d" ] && [ ! -L "${ompAgentDir}/$d" ]; then
        run rm -rf "${ompAgentDir}/$d"
      fi
      run ln -sfn "${aiDir}/omp/$d" "${ompAgentDir}/$d"
    done
  '';

  home.sessionVariables.PI_CONFIG_FILES = "${aiDir}/omp/config.yml";
  # Until zellij shows kitty's unicode placeholders: zellij-org/zellij#5530.
  home.sessionVariables.PI_NO_KITTY_PLACEHOLDERS = "1";
}

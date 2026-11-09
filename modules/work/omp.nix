{ config, lib, ... }:
{
  _class = "homeManager";

  # The work MCP servers. The shell group's aiLinks drops this link first, so a machine
  # without the work group has none.
  home.activation.ompWorkMcp = lib.hm.dag.entryAfter [ "aiLinks" ] ''
    run ln -sfn "${config.home.homeDirectory}/dotfiles/ai/omp/mcp.json" "${config.home.homeDirectory}/.omp/agent/mcp.json"
  '';
}

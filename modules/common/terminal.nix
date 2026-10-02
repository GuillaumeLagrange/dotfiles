{
  flake.modules.homeManager.terminal =
    { pkgs, lib, ... }:
    {
      options = {
        term = lib.mkOption {
          type = lib.types.str;
          default = "${pkgs.kitty}/bin/kitty";
        };

        # The default terminal for xdg-terminal-exec. kitty ships a second entry,
        # kitty-open.desktop, whose Exec (`kitty +open`) cannot run a command.
        termDesktopEntry = lib.mkOption {
          type = lib.types.str;
          default = "kitty.desktop";
        };

        # Argv prefix that runs a command in a new window of the default terminal.
        # xdg-terminal-exec resolves termDesktopEntry, and is looked up on PATH so
        # a headless host does not carry a terminal it never opens.
        termExec = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "xdg-terminal-exec" ];
        };
      };
    };
}

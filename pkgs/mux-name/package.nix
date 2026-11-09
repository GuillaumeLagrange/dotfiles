# The zellij tab name for a directory.
{ writeShellApplication, git }:

writeShellApplication {
  name = "mux-name";
  runtimeInputs = [ git ];
  text = builtins.readFile ./mux-name.sh;
}

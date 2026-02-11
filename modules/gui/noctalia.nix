{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:
{
  config = {
    programs.noctalia-shell = {
      enable = true;
      settings = builtins.fromJSON (builtins.readFile ./noctalia.json);
    };
  };
}

{ inputs, ... }:
{
  _module.args.sshPublicKey = inputs.nixpkgs.lib.trim (builtins.readFile ./headless/guiom_ssh.pub);
}

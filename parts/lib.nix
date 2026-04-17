{ inputs, ... }:
{
  _module.args.sshPublicKey = inputs.nixpkgs.lib.trim (
    builtins.readFile ../modules/headless/guiom_ssh.pub
  );
}

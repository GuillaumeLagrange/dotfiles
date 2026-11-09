{
  _class = "nixos";

  imports = [ ./oneleet.nix ];

  programs._1password.enable = true;
  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = [ "guillaume" ];
  };

  programs.oneleet.enable = true;
}

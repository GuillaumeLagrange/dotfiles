{ pkgs, ... }:
{
  _class = "homeManager";

  # niri's review bindings and 1Password autostart, the bar's PR pill.
  work.enable = true;

  programs.ssh = {
    settings = {
      "codspeeds-mac-mini*" = {
        ForwardAgent = true;
        User = "codspeed";
        RemoteForward = [
          {
            host.address = "/run/user/1000/gnupg/S.gpg-agent.extra";
            bind.address = "/Users/codspeed/.gnupg/S.gpg-agent";
          }
        ];
      };
    };
  };

  home.packages = with pkgs; [
    slack
    kdePackages.kcachegrind
    (dbeaver-bin.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ makeWrapper ];
      postFixup = (old.postFixup or "") + ''
        wrapProgram $out/bin/dbeaver --set GTK_THEME Adwaita:dark
      '';
    }))
  ];
}

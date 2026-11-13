{
  writers,
  proton-pass-cli,
  vicinae,
  wl-clipboard,
  libnotify,
  xdg-utils,
}:
writers.writePython3Bin "passwords" { doCheck = false; } (
  builtins.replaceStrings
    [ "@passCli@" "@vicinae@" "@wlCopy@" "@wlPaste@" "@notifySend@" "@xdgOpen@" ]
    [
      "${proton-pass-cli}/bin/pass-cli"
      "${vicinae}/bin/vicinae"
      "${wl-clipboard}/bin/wl-copy"
      "${wl-clipboard}/bin/wl-paste"
      "${libnotify}/bin/notify-send"
      "${xdg-utils}/bin/xdg-open"
    ]
    (builtins.readFile ./passwords.py)
)

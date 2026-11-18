# Opens a PR picked in `reviews` or the bar.
{
  writeShellApplication,
  zellij,
  gh,
  zellij-attach,
  mux-name,
  reviews,
  git,
  jq,
  gawk,
  gnugrep,
  coreutils,
  util-linux,
  libnotify,
  zellij-sessions,
}:

writeShellApplication {
  name = "review";
  runtimeInputs = [
    zellij
    gh
    zellij-attach
    mux-name
    reviews
    git
    jq
    gawk
    gnugrep
    coreutils
    util-linux
    libnotify
    zellij-sessions
  ];
  text = builtins.readFile ./review.sh;
}

{
  lib,
  rustPlatform,
  installShellFiles,
  makeWrapper,
  coreutils,
  direnv,
  fzf,
  git,
  zellij,
  mux-name,
  zellij-sessions,
  util-linux,
}:

let
  # wt also runs from non-interactive contexts: everything it calls goes on its PATH.
  runtimeInputs = [
    coreutils # cp --reflink, df
    direnv
    fzf
    git
    zellij
    mux-name
    zellij-sessions
  ];
in
rustPlatform.buildRustPackage {
  pname = "wt";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./crates
      ./Cargo.toml
      ./Cargo.lock
      ./.config
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [
    installShellFiles
    makeWrapper
  ];

  # Everything the tests drive, which fail rather than skip without it. `script`
  # gives zellij the terminal it insists on.
  useNextest = true;
  nativeCheckInputs = [
    git
    zellij
    direnv
    util-linux
  ];
  postInstall = ''
    wrapProgram $out/bin/wt --prefix PATH : ${lib.makeBinPath runtimeInputs}
    installShellCompletion --cmd wt --zsh <(COMPLETE=zsh $out/bin/wt)
  '';

  meta = {
    description = "Feature-scoped multi-repo workspaces";
    mainProgram = "wt";
  };
}

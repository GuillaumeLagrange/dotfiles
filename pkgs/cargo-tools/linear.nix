# schpet's linear-cli. Bump: `just bump linear`.
{
  lib,
  stdenv,
  rustPlatform,
  fetchFromGitHub,
  makeWrapper,
  libsecret,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "linear";
  version = "3.1.0";
  src = fetchFromGitHub {
    owner = "schpet";
    repo = "linear-cli";
    tag = "v${finalAttrs.version}";
    hash = "sha256-Bk4UPFqKVFH51iqiEhCSVfy/CX8CBnD8pHMMCIT83Pw=";
  };
  cargoHash = "sha256-FTm/RheZVjqILLM+T9JF5agZQOZF2OILI8znfZvw4Ms=";
  cargoBuildFlags = [
    "-p"
    "linear"
  ];
  doCheck = false;
  nativeBuildInputs = [ makeWrapper ];
  # Reads its key through secret-tool, which a systemd unit's PATH lacks.
  postInstall = lib.optionalString stdenv.isLinux ''
    wrapProgram $out/bin/linear --prefix PATH : ${lib.makeBinPath [ libsecret ]}
  '';
  meta.mainProgram = "linear";
})

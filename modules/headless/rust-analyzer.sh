# Stands in front of rustup's rust-analyzer proxy: adds the component to the toolchain
# picked for the cwd when it lacks it. stdout is the LSP channel, so rustup talks on stderr.
if ! rustup which rust-analyzer >/dev/null 2>&1; then
  rustup component add rust-analyzer >&2
fi
RUSTUP_FORCE_ARG0=rust-analyzer exec rustup "$@"

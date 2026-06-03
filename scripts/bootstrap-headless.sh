#!/usr/bin/env bash
#
# Bootstrap a headless box (e.g. an Ubuntu EC2 instance) with Guillaume's
# headless Home-Manager configuration.
#
# Assumes:
#   - This repository has already been cloned and the script is run from within it.
#   - A basic POSIX shell + curl are available (default on Ubuntu).
#
# Usage:
#   ./scripts/bootstrap-headless.sh
#
set -euo pipefail

# --- Resolve repo root (the script lives in <repo>/scripts) -----------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Which Home-Manager configuration to apply. The "headless" entry resolves the
# username, home directory and system from the environment (impure eval), so it
# works for whoever runs it rather than a hard-coded account.
HM_CONFIG="headless"

# getEnv (used by the "headless" flake entry) reads the *exported* environment.
# HOME is always exported; USER is not guaranteed to be, so make sure it is.
export USER="${USER:-$(id -un)}"
export HOME

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }

# --- 1. Install Nix (Determinate Systems installer) -------------------------
if command -v nix >/dev/null 2>&1; then
  log "Nix already installed: $(nix --version)"
else
  log "Installing Nix via the Determinate Systems installer..."
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install --no-confirm
fi

# Make nix available in the current shell session (the installer adds it to
# the profile, but that only affects new shells).
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

if ! command -v nix >/dev/null 2>&1; then
  warn "nix is not on PATH after install. Open a new shell and re-run, or source the nix profile."
  exit 1
fi

# --- 2. Apply the Home-Manager configuration from this flake ----------------
log "Applying Home-Manager configuration: .#${HM_CONFIG} (user: ${USER})"
nix run \
  --extra-experimental-features 'nix-command flakes' \
  --impure \
  home-manager/release-25.11 -- \
  switch --impure --flake "${REPO_ROOT}#${HM_CONFIG}" -b backup

# --- 3. Make zsh the login shell -------------------------------------------
# Home-Manager installs zsh into the user profile; point the login shell at it
# so new sessions start in the configured zsh rather than the system default.
ZSH_BIN="${HOME}/.nix-profile/bin/zsh"
if [ ! -x "${ZSH_BIN}" ]; then
  # Fall back to whatever zsh is on PATH (e.g. a system package).
  ZSH_BIN="$(command -v zsh || true)"
fi

if [ -z "${ZSH_BIN}" ]; then
  warn "zsh not found; skipping login shell change."
elif [ "$(getent passwd "${USER}" | cut -d: -f7)" = "${ZSH_BIN}" ]; then
  log "Login shell already set to ${ZSH_BIN}."
else
  log "Setting login shell to ${ZSH_BIN}..."
  # chsh requires the shell to be listed in /etc/shells.
  if ! grep -qxF "${ZSH_BIN}" /etc/shells 2>/dev/null; then
    log "Adding ${ZSH_BIN} to /etc/shells (requires sudo)..."
    echo "${ZSH_BIN}" | sudo tee -a /etc/shells >/dev/null
  fi
  if ! sudo chsh -s "${ZSH_BIN}" "${USER}"; then
    warn "Failed to change login shell. Run 'chsh -s ${ZSH_BIN}' manually."
  fi
fi

log "Done. Start a new shell (or 'exec zsh') to pick up the configuration."

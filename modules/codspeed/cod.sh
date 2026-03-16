#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="$HOME/.config/codspeed"

usage() {
  echo "Usage: cod <command>" >&2
  echo "" >&2
  echo "Commands:" >&2
  echo "  setup    Fetch secrets from 1Password and create env files" >&2
  echo "  dev      Source dev environment" >&2
  echo "  staging  Source staging environment" >&2
  echo "  prod     Clear CodSpeed environment variables" >&2
}

cmd_setup() {
  eval "$(op signin)"
  mkdir -p "$CONFIG_DIR"

  cat > "$CONFIG_DIR/dev.env" <<EOF
CODSPEED_CONFIG_NAME=dev
CODSPEED_API_URL=$(op read "op://Private/codspeed_urls/dev_api_url")
CODSPEED_UPLOAD_URL=$(op read "op://Private/codspeed_urls/dev_upload_url")
EOF

  cat > "$CONFIG_DIR/staging.env" <<EOF
CODSPEED_CONFIG_NAME=staging
CODSPEED_API_URL=$(op read "op://Private/codspeed_urls/staging_api_url")
CODSPEED_UPLOAD_URL=$(op read "op://Private/codspeed_urls/staging_upload_url")
EOF

  echo "Env files written to $CONFIG_DIR" >&2
}

cmd_env() {
  local env="$1"
  local env_file="$CONFIG_DIR/$env.env"

  if [[ ! -f "$env_file" ]]; then
    echo "Error: $env_file not found. Run 'cod setup' first." >&2
    exit 1
  fi

  # Output export statements to stdout so the caller can eval them
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    echo "export $line"
  done < "$env_file"
}

cmd_prod() {
  echo "unset CODSPEED_CONFIG_NAME"
  echo "unset CODSPEED_API_URL"
  echo "unset CODSPEED_UPLOAD_URL"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

case "$1" in
  setup)   cmd_setup ;;
  dev)     cmd_env dev ;;
  staging) cmd_env staging ;;
  prod)    cmd_prod ;;
  *)       usage; exit 1 ;;
esac

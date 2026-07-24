#!/usr/bin/env bash
# Claude Code usage for waybar — reads OAuth token from ~/.claude/.credentials.json

# shellcheck disable=SC1090,SC1091
source "${AI_USAGE_COMMON:?AI_USAGE_COMMON not set}"

CREDENTIALS="$HOME/.claude/.credentials.json"
if [ ! -f "$CREDENTIALS" ]; then
  output_error "󰜡" "No credentials file"
  exit 0
fi

force_refresh=0
if [ "${1:-}" = "--force-refresh" ]; then
  force_refresh=1
elif [ "${1:-}" = "--restart" ]; then
  clear_usage_cache "claude"
  force_refresh=1
fi

OAUTH_TOKEN_URL="https://platform.claude.com/v1/oauth/token"
OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
ROTATION_GUARD="$CACHE_DIR/claude-refresh-disabled"

# Access tokens live ~2h, so after a boot or suspend the stored one is usually
# stale. Exchange the refresh token for a fresh access token in memory only:
# Claude Code owns .credentials.json and stays the sole writer.
#
# This assumes the server does not rotate the refresh token. If it ever returns a
# new one, the stored token is already dead and only the response holds a usable
# one — writing it back would race Claude Code, so instead refreshing is disabled
# and the stale-token path takes over rather than silently breaking re-auth.
refresh_access_token() {
  [ -f "$ROTATION_GUARD" ] && return 1

  local refresh_token response http_code body
  refresh_token=$(jq -r '.claudeAiOauth.refreshToken // empty' "$CREDENTIALS")
  [ -z "$refresh_token" ] && return 1

  response=$(curl -s -w '\n%{http_code}' -X POST "$OAUTH_TOKEN_URL" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg rt "$refresh_token" --arg cid "$OAUTH_CLIENT_ID" \
      '{grant_type:"refresh_token",refresh_token:$rt,client_id:$cid}')")
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    return 1
  fi

  if [ "$(echo "$body" | jq -r 'has("refresh_token")')" = "true" ]; then
    mkdir -p "$CACHE_DIR"
    echo "refresh token rotation detected; disabling bar-side refresh" \
      > "$ROTATION_GUARD"
    return 1
  fi

  echo "$body" | jq -r '.access_token // empty'
}

access_token() {
  local expires_at now_ms token
  expires_at=$(jq -r '.claudeAiOauth.expiresAt // 0' "$CREDENTIALS")
  now_ms=$(( $(date +%s) * 1000 ))

  # 60s skew guard: avoid spending a request on a token about to expire.
  if [ "$expires_at" -gt $((now_ms + 60000)) ]; then
    jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS"
    return 0
  fi

  token=$(refresh_access_token) && [ -n "$token" ] && { echo "$token"; return 0; }

  # Refresh unavailable — fall back to the stored token and let the API judge it.
  jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS"
}

# Sets USAGE_BODY / LAST_HTTP_CODE rather than echoing, so the status code
# survives: a $(...) capture would confine the assignment to a subshell.
usage_request() {
  local token="$1" response
  response=$(curl -s -w '\n%{http_code}' "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20")
  LAST_HTTP_CODE=$(echo "$response" | tail -1)
  [[ "$LAST_HTTP_CODE" =~ ^[0-9]+$ ]] || LAST_HTTP_CODE=0
  USAGE_BODY=$(echo "$response" | sed '$d')
}

# Reports its payload via FETCH_OUTPUT (read by fetch_data_with_retries) so the
# status code in LAST_HTTP_CODE survives to the caller.
# shellcheck disable=SC2034
fetch_data() {
  local token fresh
  token=$(access_token)
  [ -z "$token" ] && { LAST_HTTP_CODE=0; return 1; }

  usage_request "$token"
  # A token that looked unexpired can still be rejected (clock skew across
  # suspend, or server-side revocation), so a 401 gets one forced refresh.
  if [ "$LAST_HTTP_CODE" = "401" ]; then
    fresh=$(refresh_access_token)
    if [ -n "$fresh" ]; then
      usage_request "$fresh"
    fi
  fi

  if [ "$LAST_HTTP_CODE" -ge 200 ] && [ "$LAST_HTTP_CODE" -lt 300 ]; then
    FETCH_OUTPUT="$USAGE_BODY"
    return 0
  fi
  FETCH_OUTPUT="$USAGE_BODY"
  return 1
}

rate_limited=0
data=$(get_cached_or_fetch "claude" 300 "$force_refresh")
rc=$?
if [ "$rc" -eq 3 ]; then
  rate_limited=1
elif [ "$rc" -eq 2 ]; then
  output_error "󰜡" "Rate limited (no cache)"
  exit 0
elif [ "$rc" -ne 0 ]; then
  output_error "󰜡" "API request failed"
  exit 0
fi

fh_pct=$(echo "$data" | jq -r '.five_hour.utilization // 0 | round')
sd_pct=$(echo "$data" | jq -r '.seven_day.utilization // 0 | round')
fh_reset=$(echo "$data" | jq -r '.five_hour.resets_at // empty')
sd_reset=$(echo "$data" | jq -r '.seven_day.resets_at // empty')

fh_eta="--"
sd_eta="--"
if [ -n "$fh_reset" ]; then
  fh_ts=$(date -d "$fh_reset" +%s 2>/dev/null)
  [ -n "$fh_ts" ] && fh_eta=$(format_eta "$fh_ts")
fi
if [ -n "$sd_reset" ]; then
  sd_ts=$(date -d "$sd_reset" +%s 2>/dev/null)
  [ -n "$sd_ts" ] && sd_eta=$(format_eta "$sd_ts")
fi

cls=$(css_class "$fh_pct")
rl_note=""
if [ "$rate_limited" -eq 1 ]; then
  rl_note="\n⚠ Rate limited — showing cached data"
fi

tooltip="Claude Code Usage\n━━━━━━━━━━━━━━━━━━━━━━━━\n5h:  ${fh_pct}%  ${fh_eta}\n7d:  ${sd_pct}%  ${sd_eta}${rl_note}"

# At 100%: show reset timer instead of percentage (7d takes priority)
bar_text="${fh_pct}%"
if [ "$sd_pct" -ge 100 ]; then
  bar_text="${sd_eta}"
elif [ "$fh_pct" -ge 100 ]; then
  bar_text="${fh_eta}"
fi

printf '{"text":"󰜡 %s","tooltip":"%s","class":"%s","percentage":%s}\n' \
  "$bar_text" "$tooltip" "$cls" "$fh_pct"

#!/usr/bin/env bash
# Pick a URL out of the surrounding pane's scrollback and open it.
set -euo pipefail

# `dump-screen` without an explicit id targets the focused pane, which is this
# floating pane. The pane to read is the other focused one in this tab: focus is
# tracked per-tab, and a floating pane and the tiled pane beneath it are both
# reported as focused.
resolve_source_pane() {
    local tab_id
    tab_id=$(zellij action current-tab-info --json | jq -r '.id // .position')

    zellij action list-panes --all --json \
        | jq -r --argjson t "$tab_id" \
            'map(select(.tab_id == $t
                        and .is_focused
                        and (.is_floating | not)
                        and (.is_plugin | not)
                        and (.is_suppressed | not)))
             | .[0].id // empty'
}

# Narrow patterns per URL kind rather than one liberal regex, following
# tmux-fzf-url. There is deliberately no generic bare-domain branch: a bare
# `foo.bar` is indistinguishable from `signal.SIGPIPE` or `numpy.float64`.
# Alternation is ordered longest-first so a scheme URL is never truncated to
# its host.
extract_urls() {
    grep -oiE \
        'mailto:[^[:space:]"'"'"'`<>]+'\
'|(https?|ftp|file|ssh|git)://[^[:space:]"'"'"'`<>]+'\
'|localhost(:[0-9]{1,5})?(/[^[:space:]"'"'"'`<>]*)?'\
'|([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]{1,5})?(/[^[:space:]"'"'"'`<>]*)?'\
'|www\.[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*\.[a-z]{2,}(:[0-9]{1,5})?(/[^[:space:]"'"'"'`<>]*)?' \
        | sed -E 's/[].,;:!?)}>"'"'"']+$//' \
        | awk 'NF' \
        | awk '!seen[$0]++'
}

die() {
    echo "$1" >&2
    sleep 1.5
    exit 0
}

source_pane=$(resolve_source_pane)
[[ -n "$source_pane" ]] || die "Could not determine which pane to read."

dump=$(mktemp -t zellij-fzf-url.XXXXXX)
trap 'rm -f "$dump"' EXIT
zellij action dump-screen --full --pane-id "terminal_$source_pane" --path "$dump"

# Reversed so the most recent URLs are at the top, where the cursor starts.
mapfile -t urls < <(extract_urls <"$dump" | tac)
[[ ${#urls[@]} -gt 0 ]] || die "No URLs found in pane."

selected=$(printf '%s\n' "${urls[@]}" | fzf \
    --reverse \
    --height=100% \
    --multi \
    --cycle \
    --scroll-off=5 \
    --no-scrollbar \
    --marker='* ' \
    --border \
    --border-label=' urls ' \
    --prompt='open > ' \
    --header='<tab> multi-select | <enter> open | <esc> cancel' \
    --header-first \
    --bind=ctrl-a:select-all \
    --exit-0) || exit 0

[[ -n "$selected" ]] || exit 0

while IFS= read -r url; do
    [[ -n "$url" ]] || continue
    # Bare hosts (www.foo, localhost:3000, 10.0.0.1) need a scheme first.
    case "$url" in
        *://* | mailto:*) target="$url" ;;
        *) target="http://$url" ;;
    esac
    xdg-open "$target" >/dev/null 2>&1 &
done <<<"$selected"

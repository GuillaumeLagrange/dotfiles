#!/usr/bin/env bash
# MPRIS data + control for the eww "now playing" widget (Terminal Deck design).
#
# Modes:
#   bar          deflisten: emit the *active* player as JSON on every MPRIS event
#                (via `playerctl --follow`). Powers the compact bar pill. Idle at
#                ~zero cost when nothing changes — no polling.
#   deck         one-shot: emit every player as a JSON array (title/artist/art/
#                position/length/progress/status). The open helper pushes this
#                once, then a 1s loop keeps it fresh only while the popup is open.
#   art <url>    resolve an artUrl to a cached local path (http(s)->download,
#                file://->strip scheme). Prints "" when unresolved.
#   playpause|next|previous <player>   transport control for one player.
#   seek <player> <ratio>              seek to ratio (0..1) of the track length.
#   open-url <player>                  xdg-open the track's xesam:url (source).
set -uo pipefail

ART_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/eww/mpris-art"

# Glyphs come from the Nix wrapper as MPRIS_ICON_* env vars. `printf '\uXXXX'`
# emits the literal escape (not the glyph) under the daemon's shell/printf, so
# the codepoints are decoded once in Nix (fromJSON) and passed in here.
player_icon() {
  case "$1" in
    spotify)           printf '%s' "${MPRIS_ICON_SPOTIFY:-}" ;;
    firefox*)          printf '%s' "${MPRIS_ICON_FIREFOX:-}" ;;
    chromium*|chrome*) printf '%s' "${MPRIS_ICON_CHROME:-}" ;;
    mpv|vlc)           printf '%s' "${MPRIS_ICON_MOVIE:-}" ;;
    *)                 printf '%s' "${MPRIS_ICON_MUSIC:-}" ;;
  esac
}

# Left-rail / accent color per player, matched to the gruvbox palette in eww.scss.
player_color() {
  case "$1" in
    spotify)           echo "green"  ;;
    firefox*)          echo "orange" ;;
    chromium*|chrome*) echo "blue"   ;;
    *)                 echo "aqua"   ;;
  esac
}

fmt_time() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# Resolve mpris:artUrl -> local path, caching downloads by URL hash. Firefox and
# mpv already hand back file:// paths; only remote http(s) art needs fetching.
resolve_art() {
  local url="$1"
  [ -z "$url" ] && { echo ""; return; }
  case "$url" in
    file://*) echo "${url#file://}"; return ;;
    http://*|https://*)
      mkdir -p "$ART_CACHE"
      local key dest
      key=$(printf '%s' "$url" | md5sum | cut -d' ' -f1)
      dest="$ART_CACHE/$key"
      [ -s "$dest" ] || curl -sfL --max-time 5 -o "$dest" "$url" 2>/dev/null || { echo ""; return; }
      echo "$dest" ;;
    *) echo "" ;;
  esac
}

# Emit one player's state as a JSON object. $1 = player instance name.
player_json() {
  local p="$1" status title artist album art_url art pos_us len_us pos len prog url
  status=$(playerctl -p "$p" status 2>/dev/null) || return 1
  [ -z "$status" ] && return 1

  title=$(playerctl -p "$p" metadata --format '{{title}}'  2>/dev/null || echo "")
  artist=$(playerctl -p "$p" metadata --format '{{artist}}' 2>/dev/null || echo "")
  album=$(playerctl -p "$p" metadata --format '{{album}}'  2>/dev/null || echo "")
  art_url=$(playerctl -p "$p" metadata mpris:artUrl        2>/dev/null || echo "")
  url=$(playerctl -p "$p" metadata xesam:url               2>/dev/null || echo "")
  len_us=$(playerctl -p "$p" metadata mpris:length         2>/dev/null || echo "0")
  # position is seconds (float); length is microseconds.
  pos=$(playerctl -p "$p" position                         2>/dev/null || echo "0")
  pos=${pos%.*}; [ -z "$pos" ] && pos=0
  len=$(( ${len_us:-0} / 1000000 ))
  prog=0
  [ "$len" -gt 0 ] && prog=$(( pos * 100 / len ))
  [ "$prog" -gt 100 ] && prog=100

  art=$(resolve_art "$art_url")

  jq -cn \
    --arg player  "$p" \
    --arg icon    "$(player_icon "$p")" \
    --arg color   "$(player_color "$p")" \
    --arg status  "$status" \
    --arg title   "$title" \
    --arg artist  "$artist" \
    --arg album   "$album" \
    --arg art     "$art" \
    --arg url     "$url" \
    --argjson pos "$pos" \
    --argjson len "$len" \
    --argjson prog "$prog" \
    --arg posText "$(fmt_time "$pos")" \
    --arg lenText "$(fmt_time "$len")" \
    '{player:$player, icon:$icon, color:$color, status:$status,
      title:$title, artist:$artist, album:$album, art:$art, url:$url,
      pos:$pos, len:$len, prog:$prog, posText:$posText, lenText:$lenText,
      playing:($status=="Playing")}'
}

player_obj() { player_json "$1"; }

# The active player is the instance playerctl selects by default (most-recently
# active). `{{playerInstance}}` disambiguates two instances of the same app.
emit_active() {
  local p obj
  p=$(playerctl metadata --format '{{playerInstance}}' 2>/dev/null || echo "")
  if [ -z "$p" ]; then echo '{"present":false}'; return; fi
  obj=$(player_obj "$p") || { echo '{"present":false}'; return; }
  echo "$obj" | jq -c '. + {present:true}'
}

emit_deck() {
  local players list=() obj
  mapfile -t players < <(playerctl -l 2>/dev/null)
  for p in "${players[@]}"; do
    [ -z "$p" ] && continue
    obj=$(player_obj "$p") && list+=("$obj")
  done
  if [ "${#list[@]}" -eq 0 ]; then echo '{"players":[]}'; return; fi
  printf '%s\n' "${list[@]}" | jq -sc '{players: .}'
}

case "${1:-bar}" in
  bar)
    # Poll the active player every second so the pill's position/meter ticks
    # while something plays. The playerctl calls are cheap; when nothing plays
    # this just re-emits {present:false}.
    while true; do
      emit_active
      sleep 1
    done
    ;;
  deck)      emit_deck ;;
  art)       resolve_art "${2:-}" ;;
  playpause) playerctl -p "${2:?player}" play-pause 2>/dev/null ;;
  next)      playerctl -p "${2:?player}" next       2>/dev/null ;;
  previous)  playerctl -p "${2:?player}" previous   2>/dev/null ;;
  seek)
    # $2 = player, $3 = ratio 0..1. Convert to absolute seconds.
    p="${2:?player}"; ratio="${3:?ratio}"
    len_us=$(playerctl -p "$p" metadata mpris:length 2>/dev/null || echo 0)
    len=$(( len_us / 1000000 ))
    target=$(awk -v r="$ratio" -v l="$len" 'BEGIN{printf "%d", r*l}')
    playerctl -p "$p" position "$target" 2>/dev/null ;;
  open-url)
    # Prefer the native app's own URI scheme so the source opens IN the app, not
    # the browser: Spotify's xesam:url is an https link (→ browser), but its
    # trackid (/com/spotify/track/<id>) maps to spotify:track:<id>, which the
    # spotify: scheme handler opens in the app.
    p="${2:?player}"
    target=""
    case "$p" in
      spotify)
        tid=$(playerctl -p "$p" metadata mpris:trackid 2>/dev/null || echo "")
        case "$tid" in
          */track/*) target="spotify:track:${tid##*/track/}" ;;
        esac ;;
    esac
    [ -z "$target" ] && target=$(playerctl -p "$p" metadata xesam:url 2>/dev/null || echo "")
    [ -n "$target" ] && xdg-open "$target" >/dev/null 2>&1 ;;
  *) echo "usage: mpris.sh {bar|deck|art|playpause|next|previous|seek|open-url}" >&2; exit 2 ;;
esac

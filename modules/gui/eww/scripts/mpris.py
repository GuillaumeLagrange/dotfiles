#!/usr/bin/env python3
"""MPRIS backend for the eww "now playing" widget — event-driven via Gio/D-Bus.

A single long-lived process holds every player's state in memory and reacts to
D-Bus signals (no polling at idle). It feeds two independent eww channels:

  state   deflisten: emit the full player list + active player, ONLY when
          something actually changes (track, status, player add/remove). Drives
          the pill and the panel rows. Blocked on the GLib main loop at idle.
  pos     deflisten: emit per-player {pos,prog,posText} every 500ms. Drives the
          seek bar / time labels only. Run ONLY while the panel is open + playing,
          so nothing rebuilds when position advances (that was the flicker).

Plus one-shot control modes: playpause|next|previous|seek|open-url|art.

Glyphs arrive as MPRIS_ICON_* env vars (decoded once in Nix — the daemon shell
mangles \\uXXXX). Session bus needs DBUS_SESSION_BUS_ADDRESS (eww user unit
inherits it).
"""
from __future__ import annotations

import hashlib
import json
import os
import signal
import subprocess
import sys
import urllib.request
from pathlib import Path

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

signal.signal(signal.SIGPIPE, signal.SIG_DFL)

MPRIS_PREFIX = "org.mpris.MediaPlayer2."
PLAYER_IFACE = "org.mpris.MediaPlayer2.Player"
OBJ_PATH = "/org/mpris/MediaPlayer2"
# playerctld is a proxy that mirrors whichever player is active — listing it
# would duplicate a real player, so it never counts as a player of its own.
PROXY_NAME = MPRIS_PREFIX + "playerctld"

ART_CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "eww" / "mpris-art"
POS_INTERVAL_MS = 500

# Title marquee — backend string rotation (the standard eww/polybar approach: no
# CSS animation, no pixel measurement). The scroll daemon slices the title into a
# fixed-width window and emits one frame per tick, so it reaches the exact end and
# the pauses are length-independent. Only runs while the panel is open.
TITLE_WINDOW = 30          # chars visible in the panel title column
SCROLL_INTERVAL_MS = 180   # per-char step
SCROLL_START_HOLD = 3      # ticks held at the start before scrolling
SCROLL_END_HOLD = 8        # ticks held at the end before reset (~1.5s at 180ms)


# ── pure helpers ─────────────────────────────────────────────────────────────

def scroll_frames(title: str) -> list[str]:
    """The full scroll sequence for a title: start-hold, one window per char step
    until the last char is at the right edge, then end-hold. Titles that fit the
    window yield a single static frame (no scrolling). Deterministic — the daemon
    just advances an index into this list, so pauses are length-independent."""
    if len(title) <= TITLE_WINDOW:
        return [title.ljust(TITLE_WINDOW)]
    slides = [title[i:i + TITLE_WINDOW] for i in range(len(title) - TITLE_WINDOW + 1)]
    return ([slides[0]] * SCROLL_START_HOLD) + slides + ([slides[-1]] * SCROLL_END_HOLD)


def short_name(bus_name: str) -> str:
    """org.mpris.MediaPlayer2.spotify -> spotify; keep instance suffix."""
    return bus_name[len(MPRIS_PREFIX):]


def icon(name: str) -> str:
    env = os.environ.get
    if name == "spotify":
        return env("MPRIS_ICON_SPOTIFY", "")
    if name.startswith("firefox"):
        return env("MPRIS_ICON_FIREFOX", "")
    if name.startswith(("chromium", "chrome")):
        return env("MPRIS_ICON_CHROME", "")
    if name.startswith(("mpv", "vlc")):
        return env("MPRIS_ICON_MOVIE", "")
    return env("MPRIS_ICON_MUSIC", "")


def color(name: str) -> str:
    if name == "spotify":
        return "green"
    if name.startswith("firefox"):
        return "orange"
    if name.startswith(("chromium", "chrome")):
        return "blue"
    return "aqua"


def fmt_time(secs: int) -> str:
    return f"{secs // 60}:{secs % 60:02d}"


def resolve_art(url: str) -> str:
    if not url:
        return ""
    if url.startswith("file://"):
        return url[len("file://"):]
    if url.startswith(("http://", "https://")):
        ART_CACHE.mkdir(parents=True, exist_ok=True)
        dest = ART_CACHE / hashlib.md5(url.encode()).hexdigest()
        if dest.exists() and dest.stat().st_size > 0:
            return str(dest)
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                dest.write_bytes(r.read())
        except Exception:
            return ""
        return str(dest)
    return ""


# ── D-Bus plumbing (synchronous calls on a shared bus) ───────────────────────

class Bus:
    def __init__(self) -> None:
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

    def list_players(self) -> list[str]:
        reply = self.bus.call_sync(
            "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
            "ListNames", None, GLib.VariantType("(as)"), Gio.DBusCallFlags.NONE, -1, None)
        # Sorted for a STABLE panel order — the active-player notion must never
        # reorder rows; only player add/remove changes this list.
        return sorted(
            n for n in reply.unpack()[0]
            if n.startswith(MPRIS_PREFIX) and n != PROXY_NAME
        )

    def active_trackid(self) -> str:
        """The trackid playerctld is currently forwarding — i.e. the player your
        media keys will hit. Empty if playerctld isn't running."""
        md = self.get_all(PROXY_NAME).get("Metadata", {}) or {}
        return str(md.get("mpris:trackid", "") or "")

    def get_all(self, bus_name: str) -> dict:
        try:
            reply = self.bus.call_sync(
                bus_name, OBJ_PATH, "org.freedesktop.DBus.Properties", "GetAll",
                GLib.Variant("(s)", (PLAYER_IFACE,)), GLib.VariantType("(a{sv})"),
                Gio.DBusCallFlags.NONE, -1, None)
            return reply.unpack()[0]
        except GLib.Error:
            return {}

    def get(self, bus_name: str, prop: str, iface: str = PLAYER_IFACE):
        try:
            reply = self.bus.call_sync(
                bus_name, OBJ_PATH, "org.freedesktop.DBus.Properties", "Get",
                GLib.Variant("(ss)", (iface, prop)), GLib.VariantType("(v)"),
                Gio.DBusCallFlags.NONE, -1, None)
            return reply.unpack()[0]
        except GLib.Error:
            return None

    def call_player(self, bus_name: str, method: str, args=None, sig=None) -> None:
        try:
            self.bus.call_sync(
                bus_name, OBJ_PATH, PLAYER_IFACE, method,
                GLib.Variant(sig, args) if sig else None, None,
                Gio.DBusCallFlags.NONE, -1, None)
        except GLib.Error:
            pass


# ── state assembly ───────────────────────────────────────────────────────────

def build_player(bus: Bus, bus_name: str, with_art: bool = True) -> dict | None:
    props = bus.get_all(bus_name)
    if not props:
        return None
    status = props.get("PlaybackStatus")
    if not status:
        return None

    md = props.get("Metadata", {}) or {}
    title = md.get("xesam:title", "") or ""
    artist_v = md.get("xesam:artist", []) or []
    artist = ", ".join(artist_v) if isinstance(artist_v, list) else str(artist_v)
    album = md.get("xesam:album", "") or ""
    len_us = int(md.get("mpris:length", 0) or 0)
    length = len_us // 1_000_000
    pos = int(props.get("Position", 0) or 0) // 1_000_000
    prog = min(100, pos * 100 // length) if length > 0 else 0
    name = short_name(bus_name)

    return {
        "player": name,
        "bus": bus_name,
        "icon": icon(name),
        "color": color(name),
        "status": status,
        "title": title,
        "artist": artist,
        "album": album,
        "art": resolve_art(md.get("mpris:artUrl", "") or "") if with_art else "",
        "url": md.get("xesam:url", "") or "",
        "trackid": str(md.get("mpris:trackid", "") or ""),
        "pos": pos,
        "len": length,
        # No mpris:length (live streams, some web media) → no meaningful progress
        # bar. The widget hides the bar/length and shows just the elapsed time.
        "has_length": length > 0,
        "prog": prog,
        "posText": fmt_time(pos),
        "lenText": fmt_time(length),
        "playing": status == "Playing",
    }


def pick_active(bus: Bus, players: list[dict]) -> dict | None:
    """The active player = whatever your media keys will hit. That is exactly
    what playerctld forwards, identified by matching its current trackid. Falls
    back to a Playing player, then the first present, if playerctld is absent."""
    if not players:
        return None
    tid = bus.active_trackid()
    if tid:
        for p in players:
            if p["trackid"] and p["trackid"] == tid:
                return p
    for p in players:
        if p["playing"]:
            return p
    return players[0]


# ── event-driven daemons ─────────────────────────────────────────────────────

class StateDaemon:
    """Emit the full state on every relevant D-Bus signal (event-driven)."""

    def __init__(self) -> None:
        self.bus = Bus()
        self.loop = GLib.MainLoop()
        self._last = None
        # Track per-player PropertiesChanged subscriptions by bus name.
        self._subs: dict[str, int] = {}

    def _emit(self) -> None:
        players = []
        for bn in self.bus.list_players():
            p = build_player(self.bus, bn)
            if p:
                players.append(p)
        active = pick_active(self.bus, players)
        payload = {
            "present": active is not None,
            "players": players,
            **({"active": active} if active else {}),
        }
        # De-dupe: only print when the meaningful state changed. Position is not
        # part of state (the pos channel owns it), so this stays quiet at idle.
        # `active.player` is in the snapshot so switching the media-key target
        # re-emits (updating the pill) even when the player set is unchanged.
        snapshot = json.dumps(
            {
                "players": [
                    {k: p[k] for k in ("player", "status", "title", "artist", "art", "len")}
                    for p in players
                ],
                "active": active["player"] if active else None,
            },
            sort_keys=True,
        )
        if snapshot == self._last:
            return
        self._last = snapshot
        print(json.dumps(payload), flush=True)

    def _on_props(self, *_args) -> None:
        self._emit()

    def _on_name_owner(self, _conn, _sender, _obj, _iface, _sig, params) -> None:
        name, old, new = params.unpack()
        if not name.startswith(MPRIS_PREFIX) or name == PROXY_NAME:
            return
        self._emit()

    def run(self) -> None:
        # PropertiesChanged from any MPRIS player (match on interface + path).
        self.bus.bus.signal_subscribe(
            None, "org.freedesktop.DBus.Properties", "PropertiesChanged", OBJ_PATH,
            None, Gio.DBusSignalFlags.NONE, self._on_props)
        # Player add/remove.
        self.bus.bus.signal_subscribe(
            "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
            "/org/freedesktop/DBus", None, Gio.DBusSignalFlags.NONE, self._on_name_owner)
        self._emit()  # initial paint
        self.loop.run()


# Panel-open flag written by the open/close helper. The pos daemon runs always
# (a deflisten can't be started on demand) but stays idle — no D-Bus calls, no
# emits — until the panel is open, so idle cost is a single wakeup per second.
OPEN_FLAG = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "eww-mpris-open"


class PosDaemon:
    """Emit per-player position every POS_INTERVAL_MS, but only while the panel
    is open. When closed it just re-arms a 1s idle timer without touching D-Bus."""

    def __init__(self) -> None:
        self.bus = Bus()
        self.loop = GLib.MainLoop()

    def _tick(self) -> bool:
        if not OPEN_FLAG.exists():
            GLib.timeout_add(1000, self._tick)
            return False  # idle: cheap re-arm, no D-Bus, no emit
        out = {}
        for bn in self.bus.list_players():
            md = self.bus.get_all(bn).get("Metadata", {}) or {}
            len_us = int(md.get("mpris:length", 0) or 0)
            pos = int(self.bus.get(bn, "Position") or 0) // 1_000_000
            length = len_us // 1_000_000
            prog = min(100, pos * 100 // length) if length > 0 else 0
            out[short_name(bn)] = {"pos": pos, "prog": prog, "posText": fmt_time(pos)}
        print(json.dumps(out), flush=True)
        GLib.timeout_add(POS_INTERVAL_MS, self._tick)
        return False

    def run(self) -> None:
        self._tick()
        self.loop.run()


class ScrollDaemon:
    """Emit each player's current title FRAME (a window slice) every
    SCROLL_INTERVAL_MS while the panel is open — backend string rotation, so the
    label just displays the frame. Advances a per-player index through
    scroll_frames(title); resets that index when the title changes. Idle (1s
    re-arm, no work) while the panel is closed."""

    def __init__(self) -> None:
        self.bus = Bus()
        self.loop = GLib.MainLoop()
        self._idx: dict[str, int] = {}       # player -> frame index
        self._title: dict[str, str] = {}     # player -> last title (reset detector)
        self._was_open = False

    def _tick(self) -> bool:
        if not OPEN_FLAG.exists():
            # On the close transition, emit ONE reset frame (index 0) so the
            # deflisten's stale value is the start of the title, not a mid-scroll
            # or hold frame — otherwise reopening the panel glimpses that state.
            if self._was_open:
                self._was_open = False
                reset = {}
                for bn in self.bus.list_players():
                    reset[short_name(bn)] = scroll_frames(
                        (self.bus.get_all(bn).get("Metadata", {}) or {}).get("xesam:title", "") or "")[0]
                print(json.dumps(reset), flush=True)
            self._idx.clear()
            self._title.clear()
            GLib.timeout_add(1000, self._tick)
            return False
        self._was_open = True
        out = {}
        seen = set()
        for bn in self.bus.list_players():
            name = short_name(bn)
            seen.add(name)
            md = self.bus.get_all(bn).get("Metadata", {}) or {}
            title = md.get("xesam:title", "") or ""
            if self._title.get(name) != title:   # new track → restart scroll
                self._title[name] = title
                self._idx[name] = 0
            frames = scroll_frames(title)
            i = self._idx.get(name, 0) % len(frames)
            out[name] = frames[i]
            self._idx[name] = (i + 1) % len(frames)
        # Drop state for players that vanished.
        for gone in [k for k in self._idx if k not in seen]:
            self._idx.pop(gone, None)
            self._title.pop(gone, None)
        print(json.dumps(out), flush=True)
        GLib.timeout_add(SCROLL_INTERVAL_MS, self._tick)
        return False

    def run(self) -> None:
        self._tick()
        self.loop.run()


# ── controls (one-shot) ──────────────────────────────────────────────────────

def resolve_bus(bus: Bus, player: str) -> str | None:
    """Map a short player name back to its current bus name."""
    for bn in bus.list_players():
        if short_name(bn) == player:
            return bn
    return None


def control(mode: str, player: str) -> None:
    bus = Bus()
    bn = resolve_bus(bus, player)
    if not bn:
        return
    if mode == "playpause":
        bus.call_player(bn, "PlayPause")
    elif mode == "next":
        bus.call_player(bn, "Next")
    elif mode == "previous":
        bus.call_player(bn, "Previous")
    elif mode == "focus":
        focus_window(bus, bn, player)


# ── compositor abstraction ───────────────────────────────────────────────────
# Only these two functions are compositor-specific. To support another Wayland
# compositor, add a branch keyed on $COMPOSITOR that returns a normalized window
# list ({id, app_id, title}) and focuses a window by id. Everything above is
# generic MPRIS/matching logic.

def focus_window(bus: Bus, bn: str, player: str) -> None:
    """Jump to the window playing this player via the MPRIS `Raise` method.

    This is compositor-agnostic and, crucially, tab-accurate: the MPRIS session is
    bound to the exact browser tab, so Firefox/Chromium Raise the window AND switch
    to the playing tab. It also crosses workspaces (tested on niri). No compositor
    IPC or window-title matching needed."""
    if not bus.get(bn, "CanRaise", "org.mpris.MediaPlayer2"):
        return
    try:
        bus.bus.call_sync(
            bn, OBJ_PATH, "org.mpris.MediaPlayer2", "Raise", None, None,
            Gio.DBusCallFlags.NONE, -1, None)
    except GLib.Error:
        pass


# ── entry ────────────────────────────────────────────────────────────────────

def main(argv: list[str]) -> int:
    mode = argv[1] if len(argv) > 1 else "state"
    if mode == "state":
        StateDaemon().run()
    elif mode == "pos":
        PosDaemon().run()
    elif mode == "scroll":
        ScrollDaemon().run()
    elif mode == "art":
        print(resolve_art(argv[2] if len(argv) > 2 else ""))
    elif mode in ("playpause", "next", "previous"):
        control(mode, argv[2])
    elif mode == "focus":
        control("focus", argv[2])
    else:
        print("usage: mpris.py {state|pos|scroll|art|playpause|next|previous|focus}",
              file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

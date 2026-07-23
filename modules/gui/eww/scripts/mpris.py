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


# ── pure helpers ─────────────────────────────────────────────────────────────

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
        return [
            n for n in reply.unpack()[0]
            if n.startswith(MPRIS_PREFIX) and n != PROXY_NAME
        ]

    def get_all(self, bus_name: str) -> dict:
        try:
            reply = self.bus.call_sync(
                bus_name, OBJ_PATH, "org.freedesktop.DBus.Properties", "GetAll",
                GLib.Variant("(s)", (PLAYER_IFACE,)), GLib.VariantType("(a{sv})"),
                Gio.DBusCallFlags.NONE, -1, None)
            return reply.unpack()[0]
        except GLib.Error:
            return {}

    def get(self, bus_name: str, prop: str):
        try:
            reply = self.bus.call_sync(
                bus_name, OBJ_PATH, "org.freedesktop.DBus.Properties", "Get",
                GLib.Variant("(ss)", (PLAYER_IFACE, prop)), GLib.VariantType("(v)"),
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
        "prog": prog,
        "posText": fmt_time(pos),
        "lenText": fmt_time(length),
        "playing": status == "Playing",
    }


def pick_active(players: list[dict]) -> dict | None:
    """Active = a Playing player if any, else the first present."""
    if not players:
        return None
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
        active = pick_active(players)
        payload = {
            "present": active is not None,
            "players": players,
            **({"active": active} if active else {}),
        }
        # De-dupe: only print when the meaningful state changed. Position is not
        # part of state (the pos channel owns it), so this stays quiet at idle.
        snapshot = json.dumps(
            [
                {k: p[k] for k in ("player", "status", "title", "artist", "art", "len")}
                for p in players
            ],
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


# ── controls (one-shot) ──────────────────────────────────────────────────────

def resolve_bus(bus: Bus, player: str) -> str | None:
    """Map a short player name back to its current bus name."""
    for bn in bus.list_players():
        if short_name(bn) == player:
            return bn
    return None


def control(mode: str, player: str, arg: str | None = None) -> None:
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
    elif mode == "seek":
        md = bus.get_all(bn).get("Metadata", {}) or {}
        len_us = int(md.get("mpris:length", 0) or 0)
        trackid = md.get("mpris:trackid", "/org/mpris/MediaPlayer2/track/0")
        target_us = int(float(arg) * len_us)
        bus.call_player(bn, "SetPosition", (trackid, target_us), "(ox)")
    elif mode == "open-url":
        open_source(bus, bn, player)


def open_source(bus: Bus, bn: str, player: str) -> None:
    md = bus.get_all(bn).get("Metadata", {}) or {}
    target = ""
    if player == "spotify":
        tid = str(md.get("mpris:trackid", "") or "")
        if "/track/" in tid:
            target = "spotify:track:" + tid.rsplit("/track/", 1)[1]
    if not target:
        target = md.get("xesam:url", "") or ""
    if target:
        Gio.AppInfo.launch_default_for_uri(target, None)


# ── entry ────────────────────────────────────────────────────────────────────

def main(argv: list[str]) -> int:
    mode = argv[1] if len(argv) > 1 else "state"
    if mode == "state":
        StateDaemon().run()
    elif mode == "pos":
        PosDaemon().run()
    elif mode == "art":
        print(resolve_art(argv[2] if len(argv) > 2 else ""))
    elif mode in ("playpause", "next", "previous"):
        control(mode, argv[2])
    elif mode == "seek":
        control("seek", argv[2], argv[3])
    elif mode == "open-url":
        control("open-url", argv[2])
    else:
        print("usage: mpris.py {state|pos|art|playpause|next|previous|seek|open-url}",
              file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

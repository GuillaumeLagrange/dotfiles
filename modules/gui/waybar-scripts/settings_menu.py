"""Waybar settings controller.

Backs a waybar `group/settings` drawer: a gear icon that expands into a row of
per-setting toggle modules. Each toggle is its own `custom/*` module that calls
one of the `*-status` commands for display and a toggle command on click.

Settings:
- Wayland idle inhibit (held by a `wlinhibit` child process, pid stored on disk)
- mako "do-not-disturb" mode

The power profile uses waybar's native `power-profiles-daemon` module; the gear
still tints its background to the active profile, read here for its class.

Each `custom/*` module refreshes on a shared signal (SIGRTMIN+9), so toggling
one repaints them all.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
from pathlib import Path

RUNTIME_DIR = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp"))
PIDFILE = RUNTIME_DIR / "waybar-focus-mode-inhibitor.pid"

ICON_GEAR = chr(0xF013)  # fa-cog
ICON_IDLE = chr(0xF06E)  # fa-eye
ICON_DND = chr(0xF1F6)  # fa-bell-slash


def inhibitor_running() -> bool:
    try:
        pid = int(PIDFILE.read_text().strip())
    except (FileNotFoundError, ValueError):
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def start_inhibitor() -> None:
    proc = subprocess.Popen(
        ["wlinhibit"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    PIDFILE.write_text(str(proc.pid))


def stop_inhibitor() -> None:
    try:
        pid = int(PIDFILE.read_text().strip())
    except (FileNotFoundError, ValueError):
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    PIDFILE.unlink(missing_ok=True)


def toggle_idle() -> None:
    if inhibitor_running():
        stop_inhibitor()
    else:
        start_inhibitor()


def dnd_enabled() -> bool:
    result = subprocess.run(
        ["makoctl", "mode"], capture_output=True, text=True, check=False
    )
    return "do-not-disturb" in result.stdout.split()


def toggle_dnd() -> None:
    subprocess.run(
        ["makoctl", "mode", "-t", "do-not-disturb"],
        check=False,
        stdout=subprocess.DEVNULL,
    )


def current_profile() -> str:
    result = subprocess.run(
        ["powerprofilesctl", "get"], capture_output=True, text=True, check=False
    )
    return result.stdout.strip() or "balanced"


def refresh_waybar() -> None:
    subprocess.run(
        ["pkill", "-RTMIN+9", "waybar"], check=False, stderr=subprocess.DEVNULL
    )


def emit(text: str, cls: str, tooltip: str) -> None:
    print(json.dumps({"text": text, "class": cls, "tooltip": tooltip}))


def gear_status() -> None:
    badges = []
    active = []
    if inhibitor_running():
        badges.append(ICON_IDLE)
        active.append("Idle inhibited")
    if dnd_enabled():
        badges.append(ICON_DND)
        active.append("Do Not Disturb")
    profile = current_profile()
    text = " ".join([*badges, ICON_GEAR])
    tooltip = " · ".join([f"Profile: {profile}", *active])
    emit(text, profile, tooltip)


def idle_status() -> None:
    on = inhibitor_running()
    emit(
        ICON_IDLE,
        "on" if on else "off",
        "Idle inhibited" if on else "Idle inhibit off",
    )


def dnd_status() -> None:
    on = dnd_enabled()
    emit(
        ICON_DND,
        "on" if on else "off",
        "Do Not Disturb on" if on else "Do Not Disturb off",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("gear-status")
    sub.add_parser("idle-status")
    sub.add_parser("dnd-status")
    sub.add_parser("toggle-idle")
    sub.add_parser("toggle-dnd")
    args = parser.parse_args()

    if args.command in (None, "gear-status"):
        gear_status()
        return
    if args.command == "idle-status":
        idle_status()
        return
    if args.command == "dnd-status":
        dnd_status()
        return

    if args.command == "toggle-idle":
        toggle_idle()
    elif args.command == "toggle-dnd":
        toggle_dnd()
    refresh_waybar()


if __name__ == "__main__":
    main()

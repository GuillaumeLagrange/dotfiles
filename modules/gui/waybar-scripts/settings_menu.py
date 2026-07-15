"""Waybar settings controller.

Backs a waybar `group/settings` drawer: a gear icon that expands into a row of
per-setting toggle modules.

Idle inhibit is waybar's native `idle_inhibitor` module, whose click both
toggles the Wayland inhibitor and flips a state file (via `idle-flip` here) so
the gear can still surface an eye badge. DND is a `custom/*` module driven by
the `*-status`/`toggle-*` commands here. The power profile uses waybar's native
`power-profiles-daemon` module; the gear tints its background to the active
profile, read here for its class.

Each `custom/*` module refreshes on a shared signal (SIGRTMIN+9), so toggling
one repaints them all.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path

RUNTIME_DIR = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp"))
IDLE_STATEFILE = RUNTIME_DIR / "waybar-idle-inhibit.state"

ICON_GEAR = chr(0xF013)  # fa-cog
ICON_IDLE = chr(0xF06E)  # fa-eye
ICON_DND = chr(0xF1F6)  # fa-bell-slash


def idle_inhibited() -> bool:
    return IDLE_STATEFILE.read_text().strip() == "on" if IDLE_STATEFILE.exists() else False


def flip_idle() -> None:
    IDLE_STATEFILE.write_text("off" if idle_inhibited() else "on")


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
    if idle_inhibited():
        badges.append(ICON_IDLE)
        active.append("Idle inhibited")
    if dnd_enabled():
        badges.append(ICON_DND)
        active.append("Do Not Disturb")
    profile = current_profile()
    text = " ".join([*badges, ICON_GEAR])
    tooltip = " · ".join([f"Profile: {profile}", *active])
    emit(text, profile, tooltip)


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
    sub.add_parser("dnd-status")
    sub.add_parser("idle-flip")
    sub.add_parser("toggle-dnd")
    args = parser.parse_args()

    if args.command in (None, "gear-status"):
        gear_status()
        return
    if args.command == "dnd-status":
        dnd_status()
        return

    if args.command == "idle-flip":
        flip_idle()
    elif args.command == "toggle-dnd":
        toggle_dnd()
    refresh_waybar()


if __name__ == "__main__":
    main()

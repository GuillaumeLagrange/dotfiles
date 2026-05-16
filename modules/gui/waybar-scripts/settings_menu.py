"""Waybar settings menu controller.

Provides toggles for:
- Wayland idle inhibit (held by a `wlinhibit` child process, pid stored on disk)
- mako "do-not-disturb" mode
- power-profiles-daemon profile (performance / balanced / power-saver)

Commands:
- `status`: emit waybar JSON describing the current power profile.
- `menu`: open the popup via the daemon (auto-spawning it if needed).
- `daemon`: run the persistent GTK process that owns the popup.
- `toggle-idle` / `toggle-dnd`: flip one state and signal waybar to refresh.
- `set-profile <name>`: switch the active power profile.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

RUNTIME_DIR = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp"))
PIDFILE = RUNTIME_DIR / "waybar-focus-mode-inhibitor.pid"
SOCKET_PATH = RUNTIME_DIR / "waybar-settings-menu.sock"

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


def set_profile(name: str) -> None:
    subprocess.run(
        ["powerprofilesctl", "set", name],
        check=False,
        stdout=subprocess.DEVNULL,
    )


def refresh_waybar() -> None:
    subprocess.run(
        ["pkill", "-RTMIN+9", "waybar"], check=False, stderr=subprocess.DEVNULL
    )


def status() -> None:
    profile = current_profile()
    parts = [f"Profile: {profile}"]
    badges = []
    if inhibitor_running():
        parts.append("Idle inhibited")
        badges.append(ICON_IDLE)
    if dnd_enabled():
        parts.append("Do Not Disturb")
        badges.append(ICON_DND)
    text = " ".join([*badges, ICON_GEAR])
    print(json.dumps({"text": text, "class": profile, "tooltip": " · ".join(parts)}))


def run_daemon() -> None:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("GtkLayerShell", "0.1")
    from gi.repository import Gtk, Gdk, GLib, GtkLayerShell

    css = b"""
    .settings-popup {
        background-color: #2b303b;
        color: #ffffff;
        border: 1px solid #6c6f64;
        border-radius: 6px;
        padding: 8px;
    }
    .settings-popup separator {
        background-color: #6c6f64;
        min-height: 1px;
        margin: 4px 0;
    }
    """
    provider = Gtk.CssProvider()
    provider.load_from_data(css)
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(),
        provider,
        Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    )

    state = {"win": None}

    def close():
        win = state["win"]
        if win is not None:
            state["win"] = None
            win.destroy()

    def show_popup():
        close()

        win = Gtk.Window()
        win.set_decorated(False)
        win.set_resizable(False)
        win.get_style_context().add_class("settings-popup")

        GtkLayerShell.init_for_window(win)
        GtkLayerShell.set_layer(win, GtkLayerShell.Layer.OVERLAY)
        GtkLayerShell.set_anchor(win, GtkLayerShell.Edge.BOTTOM, True)
        GtkLayerShell.set_anchor(win, GtkLayerShell.Edge.RIGHT, True)
        GtkLayerShell.set_margin(win, GtkLayerShell.Edge.BOTTOM, 26)
        GtkLayerShell.set_margin(win, GtkLayerShell.Edge.RIGHT, 8)
        GtkLayerShell.set_keyboard_mode(win, GtkLayerShell.KeyboardMode.EXCLUSIVE)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        box.set_border_width(6)
        win.add(box)

        def on_idle(btn):
            if inhibitor_running() != btn.get_active():
                toggle_idle()
                refresh_waybar()
            close()

        def on_dnd(btn):
            if dnd_enabled() != btn.get_active():
                toggle_dnd()
                refresh_waybar()
            close()

        def on_profile(btn, name):
            if btn.get_active() and current_profile() != name:
                set_profile(name)
                refresh_waybar()
                close()

        idle_btn = Gtk.CheckButton(label="Inhibit idle")
        idle_btn.set_active(inhibitor_running())
        idle_btn.connect("toggled", on_idle)
        box.pack_start(idle_btn, False, False, 0)

        dnd_btn = Gtk.CheckButton(label="Do Not Disturb")
        dnd_btn.set_active(dnd_enabled())
        dnd_btn.connect("toggled", on_dnd)
        box.pack_start(dnd_btn, False, False, 0)

        box.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 4)

        active_profile = current_profile()
        group_head = None
        for name, label in (
            ("performance", "Performance"),
            ("balanced", "Balanced"),
            ("power-saver", "Power saver"),
        ):
            btn = Gtk.RadioButton.new_with_label_from_widget(group_head, label)
            btn.set_active(name == active_profile)
            btn.connect("toggled", on_profile, name)
            group_head = group_head or btn
            box.pack_start(btn, False, False, 0)

        def on_key(_w, event):
            if event.keyval == Gdk.KEY_Escape:
                close()

        win.connect("key-press-event", on_key)
        win.connect("focus-out-event", lambda *_: (close(), False)[1])

        state["win"] = win
        win.show_all()

    def on_socket(source, condition):
        try:
            conn, _ = source.accept()
        except BlockingIOError:
            return True
        with conn:
            try:
                data = conn.recv(64).decode().strip()
            except OSError:
                return True
            if data == "show":
                show_popup()
            elif data == "quit":
                Gtk.main_quit()
        return True

    try:
        SOCKET_PATH.unlink()
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(SOCKET_PATH))
    srv.listen(4)
    srv.setblocking(False)
    GLib.io_add_watch(srv.fileno(), GLib.IO_IN, lambda *_: on_socket(srv, None))

    def on_signal():
        Gtk.main_quit()
        return False

    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, on_signal)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, on_signal)

    Gtk.main()
    try:
        SOCKET_PATH.unlink()
    except FileNotFoundError:
        pass


def send_to_daemon(message: str, retries: int = 20) -> bool:
    for _ in range(retries):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.connect(str(SOCKET_PATH))
                s.sendall(message.encode())
            return True
        except (FileNotFoundError, ConnectionRefusedError):
            time.sleep(0.05)
    return False


def ensure_daemon() -> None:
    if SOCKET_PATH.exists():
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(0.1)
                s.connect(str(SOCKET_PATH))
            return
        except OSError:
            pass
    subprocess.Popen(
        [sys.executable, __file__, "daemon"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def open_menu() -> None:
    ensure_daemon()
    send_to_daemon("show")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("status")
    sub.add_parser("menu")
    sub.add_parser("daemon")
    sub.add_parser("toggle-idle")
    sub.add_parser("toggle-dnd")
    set_p = sub.add_parser("set-profile")
    set_p.add_argument("profile", choices=("performance", "balanced", "power-saver"))
    args = parser.parse_args()

    if args.command in (None, "status"):
        status()
        return
    if args.command == "menu":
        open_menu()
        return
    if args.command == "daemon":
        run_daemon()
        return
    if args.command == "toggle-idle":
        toggle_idle()
    elif args.command == "toggle-dnd":
        toggle_dnd()
    elif args.command == "set-profile":
        set_profile(args.profile)
    refresh_waybar()


if __name__ == "__main__":
    main()

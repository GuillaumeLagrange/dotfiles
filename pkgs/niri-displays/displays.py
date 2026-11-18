"""Saved display setups for niri, picked at runtime instead of declared in its config.

A setup is the monitors it turns on, with their mode, scale, transform,
position and VRR. It is saved from whatever niri shows (arranged with wdisplays
or `niri msg output`), fits wherever those monitors are connected, and turns
off any other.

  niri-displays list          the setups and the connected monitors, as JSON
  niri-displays save NAME     save the current layout as NAME, replacing one so named
  niri-displays apply NAME
  niri-displays delete NAME
  niri-displays rename OLD NEW
  niri-displays order NAME...  put the setups in this order, any left out after them
  niri-displays watch         when the connected monitors change, apply the setup last used with them

Monitors are known by "make model serial", the name niri's config matches,
so a setup follows a monitor from one port to another.
"""

import json
import os
import selectors
import socket
import subprocess
import sys
import time

NIRI = "@niri@"

STATE = os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
    "niri-displays",
)
SETUPS = os.path.join(STATE, "setups.json")

TRANSFORMS = {
    "Normal": "normal",
    "_90": "90",
    "_180": "180",
    "_270": "270",
    "Flipped": "flipped",
    "Flipped90": "flipped-90",
    "Flipped180": "flipped-180",
    "Flipped270": "flipped-270",
}


def runtime(name):
    return os.path.join(os.environ["XDG_RUNTIME_DIR"], f"niri-displays-{name}")


def connect():
    sock = socket.socket(socket.AF_UNIX)
    sock.connect(os.environ["NIRI_SOCKET"])
    return sock


def request(req):
    with connect() as sock:
        sock.sendall((json.dumps(req) + "\n").encode())
        reply = json.loads(sock.makefile().readline())
    if "Ok" not in reply:
        raise RuntimeError(f"niri refused {req}: {reply}")
    return reply["Ok"]


def label(out):
    if out["name"].startswith(("eDP", "LVDS", "DSI")):
        return "Built-in"
    model = (out["model"] or "").split()
    return model[-1] if model and model[-1] != "Unknown" else out["name"]


def connected():
    """The connected monitors by id, with what a setup records of them."""
    outs = request("Outputs")["Outputs"].values()
    ids = {}
    for out in outs:
        key = f"{out['make']} {out['model']} {out['serial'] or 'Unknown'}"
        ids.setdefault(key, []).append(out)
    current = {}
    for key, same in ids.items():
        for out in same:
            # Twins without a serial are told apart by port.
            current[key if len(same) == 1 else f"{key} ({out['name']})"] = out
    return current


def record(key, out):
    rec = {"id": key, "label": label(out), "on": out["current_mode"] is not None}
    if rec["on"]:
        mode = out["modes"][out["current_mode"]]
        logical = out["logical"]
        rec |= {
            "mode": {k: mode[k] for k in ("width", "height", "refresh_rate")},
            "scale": logical["scale"],
            "transform": logical["transform"],
            "x": logical["x"],
            "y": logical["y"],
            "w": logical["width"],
            "h": logical["height"],
        }
        if out["vrr_supported"]:
            rec["vrr"] = out["vrr_enabled"]
    return rec


def snapshot(current):
    return [record(key, out) for key, out in sorted(current.items())]


def plugged(ids):
    """The key a setup's use is recorded under: the monitors connected then."""
    return " + ".join(sorted(ids))


def load():
    try:
        with open(SETUPS) as f:
            setups = json.load(f)["setups"]
    except FileNotFoundError:
        return []
    for s in setups:
        # Setups saved when they recorded the monitors they turned off, and one time of use.
        if not isinstance(s.get("used", {}), dict):
            s["used"] = {plugged(o["id"] for o in s["outputs"]): s["used"]}
        s["outputs"] = [o for o in s["outputs"] if o["on"]]
    return setups


def store(setups):
    os.makedirs(STATE, exist_ok=True)
    tmp = SETUPS + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"setups": setups}, f, indent=2)
    os.replace(tmp, SETUPS)


def fits(setup, current):
    return all(o["id"] in current for o in setup["outputs"])


def same(rec, now):
    if rec["on"] != now["on"]:
        return False
    if not rec["on"]:
        return True
    keys = ("mode", "transform", "x", "y", "vrr")
    return all(rec.get(k) == now.get(k) for k in keys) and (
        abs(rec["scale"] - now["scale"]) < 1e-3
    )


def active(setup, current):
    if not fits(setup, current):
        return False
    now = {r["id"]: r for r in snapshot(current)}
    ids = {o["id"] for o in setup["outputs"]}
    return all(same(o, now[o["id"]]) for o in setup["outputs"]) and not any(
        r["on"] for key, r in now.items() if key not in ids
    )


def output(name, *args):
    subprocess.run([NIRI, "msg", "output", name, *args], check=True)


def apply(setup, login=False):
    current = connected()
    if not fits(setup, current):
        raise SystemExit(f"{setup['name']!r} is for other monitors")
    now = {r["id"]: r for r in snapshot(current)}
    changed = not active(setup, current)
    focused = request("FocusedOutput")["FocusedOutput"]
    # Monitors are turned on before others are turned off, so the session is never left without one.
    for rec in setup["outputs"]:
        name, was = current[rec["id"]]["name"], now[rec["id"]]
        if not was["on"]:
            output(name, "on")
        mode = rec["mode"]
        if was.get("mode") != mode:
            refresh = f"{mode['refresh_rate'] / 1000:.3f}"
            output(name, "mode", f"{mode['width']}x{mode['height']}@{refresh}")
        if was.get("scale") is None or abs(was["scale"] - rec["scale"]) >= 1e-3:
            output(name, "scale", str(rec["scale"]))
        if was.get("transform") != rec["transform"]:
            output(name, "transform", TRANSFORMS[rec["transform"]])
        # Even where it already is: an output niri placed itself moves out of the way of the others.
        output(name, "position", "set", "--", str(rec["x"]), str(rec["y"]))
        if "vrr" in rec and was.get("vrr") != rec["vrr"]:
            output(name, "vrr", "on" if rec["vrr"] else "off")
    ids = {o["id"] for o in setup["outputs"]}
    for key, was in now.items():
        if key not in ids and was["on"]:
            output(current[key]["name"], "off")
    if changed:
        # niri leaves the cursor where it was, now maybe on another output than
        # the focused one: focusing again puts it back. At login, niri focused
        # the first output by name; the top-left one is taken instead.
        on = {current[r["id"]]["name"]: r for r in setup["outputs"]}
        if login or focused is None or focused["name"] not in on:
            target = min(on, key=lambda name: (on[name]["y"], on[name]["x"]))
        else:
            target = focused["name"]
        request({"Action": {"FocusMonitor": {"output": target}}})
    setups = load()
    for s in setups:
        if s["name"] == setup["name"]:
            s["used"][plugged(current)] = time.time()
    store(setups)


def find(name):
    setup = next((s for s in load() if s["name"] == name), None)
    if setup is None:
        raise SystemExit(f"no setup named {name!r}")
    return setup


def save(name):
    setups = load()
    current = connected()
    outputs = [r for r in snapshot(current) if r["on"]]
    setup = {"name": name, "outputs": outputs, "used": {plugged(current): time.time()}}
    at = next((i for i, s in enumerate(setups) if s["name"] == name), None)
    if at is None:
        setups.append(setup)
    else:
        setups[at] = setup
    store(setups)


def delete(name):
    store([s for s in load() if s["name"] != name])


def rename(old, new):
    setups = load()
    setup = next((s for s in setups if s["name"] == old), None)
    if setup is None:
        raise SystemExit(f"no setup named {old!r}")
    if new != old and any(s["name"] == new for s in setups):
        raise SystemExit(f"a setup is already named {new!r}")
    setup["name"] = new
    store(setups)


def order(names):
    setups = load()
    rank = {name: i for i, name in enumerate(names)}
    setups.sort(key=lambda s: rank.get(s["name"], len(names)))
    store(setups)


def listing():
    current = connected()
    setups = [
        {
            "name": s["name"],
            "fits": fits(s, current),
            "active": active(s, current),
            "outputs": s["outputs"],
        }
        for s in load()
    ]
    return {"connected": snapshot(current), "setups": setups}


def settle():
    """Once the connected monitors differ from those seen last in this niri
    session, applies the setup last used with exactly them, else the one
    turning the most of them on, the last used first."""
    current = connected()
    seen = {"socket": os.environ["NIRI_SOCKET"], "ids": sorted(current)}
    login = True
    try:
        with open(runtime("seen")) as f:
            last = json.load(f)
        if last == seen:
            return
        login = last.get("socket") != seen["socket"]
    except (FileNotFoundError, ValueError):
        pass
    fitting = [s for s in load() if fits(s, current)]
    if not fitting:
        print(f"no setup for {seen['ids']}", flush=True)
    else:
        key = plugged(current)
        setup = max(
            fitting,
            key=lambda s: (
                key in s["used"],
                s["used"].get(key) or len(s["outputs"]),
                max(s["used"].values(), default=0),
            ),
        )
        if not active(setup, current):
            print(f"applying {setup['name']!r}", flush=True)
            apply(setup, login)
    # Written last: a failed apply is retried when the unit restarts.
    with open(runtime("seen"), "w") as f:
        json.dump(seen, f)


def watch():
    # niri's event stream has no output event, but a monitor coming or going
    # moves workspaces: the outputs are compared once each burst settles.
    with connect() as sock:
        sock.sendall(b'"EventStream"\n')
        sel = selectors.DefaultSelector()
        sel.register(sock, selectors.EVENT_READ)
        settle()
        print("watching", flush=True)
        due = None
        while True:
            timeout = None if due is None else max(0.0, due - time.monotonic())
            if sel.select(timeout):
                if not sock.recv(65536):
                    return 1
                if due is None:
                    due = time.monotonic() + 0.5
            else:
                due = None
                settle()


def main(args):
    match args:
        case ["list"]:
            print(json.dumps(listing()))
        case ["save", name] if name.strip():
            save(name.strip())
        case ["apply", name]:
            apply(find(name))
        case ["delete", name]:
            delete(name)
        case ["rename", old, new] if new.strip():
            rename(old, new.strip())
        case ["order", *names]:
            order(names)
        case ["watch"]:
            return watch()
        case _:
            print(__doc__, file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

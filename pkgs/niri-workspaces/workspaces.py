"""sway-like numbered workspaces on niri: a number exists while it holds windows
or is on screen, is unique across outputs, and is created where you go to it.

  niri-workspaces focus N   go to N, creating it on the focused output
  niri-workspaces move N    send the focused column to N, creating it there
  niri-workspaces sort      put each output's named workspaces in order
  niri-workspaces watch [--assign APP_ID_REGEX=N]...
      keep it so: drop the name of an empty workspace left behind, give the
      lowest free number to an unnamed one that gets a window or is shown,
      send new matching windows to N

Talks to niri's socket rather than `niri msg`, which reads "1" as an index.
"""

import itertools
import json
import os
import re
import selectors
import socket
import sys
import time


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


def action(kind, **args):
    request({"Action": {kind: args}})


def ref(ws):
    return {"Id": ws["id"]}


def workspaces():
    return request("Workspaces")["Workspaces"]


def empty(ws):
    return ws["active_window_id"] is None


def order(ws):
    name = ws["name"]
    return (0, int(name), "") if name.isdigit() else (1, 0, name)


def misplaced(wss):
    """The first named workspace not at its place in order on its output, and that place."""
    outputs = {}
    for ws in wss:
        if ws["name"] is not None:
            outputs.setdefault(ws["output"], []).append(ws)
    for named in outputs.values():
        for idx, ws in enumerate(sorted(named, key=order), 1):
            if ws["idx"] != idx:
                return ws, idx
    return None


def sort():
    # One move per pass, bounded so a move niri ignores cannot spin forever.
    for _ in range(100):
        move = misplaced(workspaces())
        if move is None:
            return
        ws, idx = move
        action("MoveWorkspaceToIndex", index=idx, reference=ref(ws))
    raise RuntimeError("workspaces still unsorted after 100 moves")


def find(wss, name):
    """The workspace named `name`, else an empty unnamed one to name so: niri
    keeps one at the end of each output. True when it has to be named."""
    for ws in wss:
        if ws["name"] == name:
            return ws, False
    output = next(ws for ws in wss if ws["is_focused"])["output"]
    blank = [
        ws for ws in wss if ws["output"] == output and ws["name"] is None and empty(ws)
    ]
    return max(blank, key=lambda ws: ws["idx"]), True


def focus(name):
    wss = workspaces()
    target, new = find(wss, name)
    # Created and put in place before the switch: moving a workspace cancels
    # niri's switch animation, so the switch then slides like to an old one.
    if new:
        action("SetWorkspaceName", name=name, workspace=ref(target))
        sort()
    # Only what target replaces on its output is left; another output's stays shown.
    left = next(
        ws for ws in wss if ws["is_active"] and ws["output"] == target["output"]
    )
    if left["id"] != target["id"] and left["name"] is not None and empty(left):
        # Unnamed before it is left, niri removes it on the switch.
        action("UnsetWorkspaceName", reference=ref(left))
    action("FocusWorkspace", reference=ref(target))


def move(name):
    target, new = find(workspaces(), name)
    if new:
        action("SetWorkspaceName", name=name, workspace=ref(target))
    action("MoveColumnToWorkspace", reference=ref(target), focus=False)
    if new:
        sort()


def tidy(assign, seen):
    windows = request("Windows")["Windows"]
    for window in windows:
        if window["id"] in seen:
            continue
        seen.add(window["id"])
        for pattern, name in assign:
            if re.search(pattern, window["app_id"] or ""):
                wss = workspaces()
                target, new = find(wss, name)
                if new:
                    action("SetWorkspaceName", name=name, workspace=ref(target))
                if window["workspace_id"] != target["id"]:
                    action(
                        "MoveWindowToWorkspace",
                        window_id=window["id"],
                        reference=ref(target),
                        focus=False,
                    )
                break
    seen.intersection_update(w["id"] for w in windows)

    wss = sorted(workspaces(), key=lambda ws: (ws["output"] or "", ws["idx"]))
    for ws in wss:
        if ws["name"] is not None and empty(ws) and not ws["is_active"]:
            action("UnsetWorkspaceName", reference=ref(ws))
            ws["name"] = None
    names = {ws["name"] for ws in wss if ws["name"] is not None}
    for ws in wss:
        if ws["name"] is None and (ws["is_active"] or not empty(ws)):
            name = next(str(i) for i in itertools.count(1) if str(i) not in names)
            names.add(name)
            action("SetWorkspaceName", name=name, workspace=ref(ws))
    sort()


def watch(assign):
    with connect() as sock:
        sock.sendall(b'"EventStream"\n')
        sel = selectors.DefaultSelector()
        sel.register(sock, selectors.EVENT_READ)
        seen = {w["id"] for w in request("Windows")["Windows"]}
        tidy(assign, seen)
        print("watching", flush=True)
        # Events come in bursts, ours included: tidy once a burst has had time
        # to settle, so a `focus`/`move` mid-way is not taken for a stray state.
        due = None
        while True:
            timeout = None if due is None else max(0.0, due - time.monotonic())
            if sel.select(timeout):
                if not sock.recv(65536):
                    return 1
                if due is None:
                    due = time.monotonic() + 0.2
            else:
                due = None
                tidy(assign, seen)


def main(args):
    match args:
        case ["focus", name]:
            focus(name)
        case ["move", name]:
            move(name)
        case ["sort"]:
            sort()
        case ["watch", *rest] if all(
            a.startswith("--assign=") and "=" in a[9:] for a in rest
        ):
            return watch([tuple(a[9:].rsplit("=", 1)) for a in rest])
        case _:
            print(__doc__, file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

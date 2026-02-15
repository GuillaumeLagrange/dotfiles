import json
import subprocess


EVENTS = {
    "WindowsChanged",
    "WindowOpenedOrChanged",
    "WindowClosed",
    "WindowFocusChanged",
    "WorkspacesChanged",
    "WorkspaceActivated",
    "WorkspaceActiveWindowChanged",
    "OverviewOpenedOrClosed",
}


def query(cmd):
    result = subprocess.run(
        ["niri", "msg", "--json", cmd],
        capture_output=True, text=True,
    )
    return json.loads(result.stdout)


def output():
    workspaces = query("workspaces")
    windows = query("windows")
    overview = query("overview-state")

    focused_ws = next((ws for ws in workspaces if ws.get("is_focused")), None)
    if focused_ws is None:
        print(json.dumps({"text": "", "tooltip": "", "class": "empty"}),
              flush=True)
        return

    ws_id = focused_ws["id"]
    active_window_id = focused_ws.get("active_window_id")
    ws_windows = [w for w in windows if w.get("workspace_id") == ws_id]
    ws_windows.sort(
        key=lambda w: ((w.get("layout") or {})
                       .get("pos_in_scrolling_layout") or [0])[0]
    )

    count = len(ws_windows)
    if count == 0:
        print(json.dumps({"text": "", "tooltip": "", "class": "empty"}),
              flush=True)
        return

    dots = []
    for w in ws_windows:
        if w.get("is_focused"):
            dots.append("\u25cf")
        elif overview["is_open"] and w["id"] == active_window_id:
            dots.append("\u25cf")
        else:
            dots.append("\u25cb")

    text = " ".join(dots)
    tooltip = f"{count} window{'s' if count != 1 else ''}"
    print(json.dumps({"text": text, "tooltip": tooltip,
                      "class": "has-windows"}), flush=True)


proc = subprocess.Popen(
    ["niri", "msg", "--json", "event-stream"],
    stdout=subprocess.PIPE,
    text=True,
)

for line in proc.stdout:
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue

    if any(key in event for key in EVENTS):
        output()

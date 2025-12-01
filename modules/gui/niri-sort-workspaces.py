import json
import subprocess
import sys


def run_niri_cmd(*args):
    """Run a niri msg command"""
    cmd = ["niri", "msg"] + list(args)
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.stdout.strip()


def get_workspaces():
    """Fetch current workspaces with their output, index, and active status"""
    output = run_niri_cmd("--json", "workspaces")
    workspaces = json.loads(output)
    result = []
    for ws in workspaces:
        if ws.get("name") is not None:
            result.append(
                {
                    "name": ws["name"],
                    "output": ws.get("output"),
                    "idx": ws.get("idx"),
                    "is_focused": ws.get("is_focused", False),
                }
            )
    return result


def main():
    # Iteratively move one workspace at a time until all are sorted
    while True:
        # Get current workspaces
        workspaces = get_workspaces()

        # Group workspaces by output
        outputs = {}
        for ws in workspaces:
            output = ws["output"]
            if output not in outputs:
                outputs[output] = []
            outputs[output].append(ws)

        # Find the first workspace that needs moving
        workspace_to_move = None
        for output, ws_list in outputs.items():
            # Sort by index to get current order
            ws_list.sort(key=lambda w: w["idx"])
            current_order = [w["name"] for w in ws_list]
            sorted_order = sorted(current_order)

            if current_order != sorted_order:
                # Find the first misplaced workspace
                for target_idx, target_name in enumerate(sorted_order):
                    current_ws = next(w for w in ws_list if w["name"] == target_name)
                    current_idx = current_ws["idx"]

                    if current_idx != target_idx + 1:  # +1 because idx is 1-based
                        workspace_to_move = {
                            "name": target_name,
                            "target_idx": target_idx + 1,
                            "current_idx": current_idx,
                            "output": output,
                        }
                        break

            if workspace_to_move:
                break

        # If no workspace needs moving, we're done
        if not workspace_to_move:
            print("All workspaces are sorted!")
            return 0

        # Move the workspace
        print(
            f"Moving '{workspace_to_move['name']}' on {workspace_to_move['output']}: "
            f"index {workspace_to_move['current_idx']} → {workspace_to_move['target_idx']}"
        )

        # Move it to the target index
        run_niri_cmd(
            "action",
            "move-workspace-to-index",
            "--reference",
            workspace_to_move["name"],
            str(workspace_to_move["target_idx"]),
        )


if __name__ == "__main__":
    sys.exit(main())

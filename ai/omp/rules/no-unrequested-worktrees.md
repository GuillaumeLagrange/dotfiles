---
name: no-unrequested-worktrees
description: "Never create git worktrees or workspaces outside /tmp on your own; work in the checkout the user names"
condition: ["worktree add[^\\n;&|]*\\s(\\.\\./|~/|/home/)", "\\b\\w+=(\\.\\./|~/|/home/)\\S*\\s*(&&|;)[^\\n]*worktree add"]
scope: "tool:bash"
---

Do not create new worktrees, clones or workspace directories outside `/tmp` unless the user asked for one.

- When the user names a directory (e.g. `../platform`), work in the worktree that is checked out there, on its current branch.
- If that checkout looks wrong for the task (wrong branch, dirty tree, a branch that lacks the change), stop and tell the user what is amiss so they can fix it. Do not work around it by adding another worktree or switching branches yourself.
- Throwaway scaffolding (smoke-test remotes, scratch clones) belongs under `/tmp` (`mktemp -d`) and is removed afterwards.
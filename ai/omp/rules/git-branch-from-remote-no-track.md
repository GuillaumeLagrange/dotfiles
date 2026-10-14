---
name: git-branch-from-remote-no-track
description: "Creating a branch from origin/<base> without --no-track sets the wrong upstream (origin/main), breaking `git push`"
condition: "git\\s+(?![^\\n]*--no-track)(?:switch\\s+(?:-c|--create)|checkout\\s+-b)\\s+\\S+\\s+origin/"
scope: "tool:bash"
---

Creating a branch from a remote-tracking ref (`git switch -c feat origin/main`, `git checkout -b feat origin/main`) makes git set the branch's upstream to `origin/main`. Then `git push` fails with "upstream branch does not match the name of your current branch", or worse, pushes to main.

Do this instead:
- `git switch -c <branch> --no-track origin/main` (or `git checkout -b <branch> --no-track origin/main`), or
- update the local base first (`git fetch origin && git switch main && git merge --ff-only origin/main`), then `git switch -c <branch>`.

The first push then sets the correct upstream: `git push -u origin <branch>`. If a branch already tracks the wrong ref, fix it with `git branch --unset-upstream` before pushing.
# wt

Feature-scoped workspaces spanning several repos: a set of worktrees inside a
mirror of the whole checkout, so every sibling path keeps resolving.

The design, and the reasoning behind it, is in [`../wt.md`](../wt.md). It is cut into
milestones there; built so far are the session directories and the zellij session on
top of them. The agent dashboard is not.

```
wt                 attach to a session, picking one when none is named
wt <id>            the same, by name or unique prefix
wt new <name>      pick members, mirror the workspace, check them out detached
wt add <repo>      turn a mirror symlink into a worktree, and open a tab for it
wt promote <repo>  the swap backwards: the main checkout takes the branch
wt rm [<id>]       guarded teardown (dirty tree / unpushed / stashes; --force)
wt ls [--json]     sessions, members, branches
wt path [<id>]     a session root, for shell use; --exact, for a name from elsewhere
wt sync [--fix]    drift report / repair
```

## Layout

```
crates/core/     registry, mirror, hydration, git, branch, drift, zellij
crates/cli/      the `wt` binary
crates/cli/tests/  the end-to-end suite
```

## Build

The CLI is packaged (`modules/headless/wt.nix`), so a `home-manager switch` is
enough. For the dev loop:

```sh
cargo build            # or: nix shell nixpkgs#cargo nixpkgs#rustc --command cargo build
cargo nextest run      # unit tests and the end-to-end suite
```

The suite in `crates/cli/tests/` drives the built binary against a throwaway
workspace: real git repos, real worktrees, its own `HOME` and XDG directories, so a
test can neither read nor damage the machine's own sessions. `common::Fixture` builds
one per test, and drops it on the way out. The zellij tests start real servers —
isolated by the fixture's `XDG_RUNTIME_DIR` and `XDG_CACHE_HOME` — and skip with a
note when zellij is not installed; the same goes for the direnv test.

## Configuration

`~/.config/wt/config.toml`, written by hand — naming the repos wt may touch
describes a codebase, which is not something to commit to a dotfiles repo. Nothing
about a particular workspace is compiled in either, so `workspace` is required;
every other key has a default:

```toml
workspace = "~/work"                 # the multi-repo checkout to mirror; else $WT_WORKSPACE
default_root = "~/work/sessions"     # default: <workspace>/sessions
repos = ["app", "docs", "lib"]       # the picker's pre-approved list; default: every repo
hydrate = [".envrc", ".env*"]        # git-ignored paths a worktree needs; see below
```

Unknown keys are an error rather than a shrug, so a typo says so.

`WORKSPACE_ROOT` is deliberately *not* read: inside a session it points at the
mirror, not at the checkout the mirror was built from.

Repo names and branch names are never hardcoded. Members come from `repos`, and
each one is checked out **detached** at its own main branch — `origin/HEAD`, else a
`GIT_MAIN_BRANCH` that resolves there, else whichever of `main`/`master`/`staging`/
`trunk`/`develop` exists. Naming a branch is left to whoever does the work.

Hydration copies the paths `hydrate` names, as they stand, and runs `direnv allow`.
Which git-ignored files a worktree is unusable without is a property of a codebase,
so the list is configuration; the default is `.envrc`, `.env*`, `.nvim.lua`,
`.taplo.toml`, `.claude/settings.local.json`. A pattern with no `/` matches a name
at any depth, one with a `/` matches the path from the repo root, and `*` stands for
any run of characters within a single name. An empty list is taken at its word.

Keep it to *environment*. Anything heavier — installed dependencies, generated code
— belongs in the repo's own `post-checkout` hook, and state does not travel at all:
a `Session.vim` records a cwd and absolute paths, so a copy restores the checkout it
was written in.

## The session root

`WORKSPACE_ROOT` points at the session, so anything resolving paths against it
lands in the session's own repos. It is a property of the **session**, not of a
directory: `cd ~` inside one must not send `cdr` back to the workspace, which rules
out direnv.

It is set for a whole zellij session by **starting its server with it in the
environment**: panes inherit the server's environment, and the server inherits the
environment of whoever started it — on creation and on resurrection alike, since both
start a server. `wt <id>` is that starter, and `zsm` does the same when `wt path
--exact <name>` resolves a session it was given by name.

`wt <id>` always brings the server up itself, detached, before doing anything else —
even when it is only going to switch to it from inside another session, because
letting zellij's own server spawn the target would hand it an environment that never
saw the root.

Nothing is written for zellij to read. A generated layout would work too, but a
layout — like `--config` — *replaces* what it is given rather than adding to it, so
carrying one variable would mean restating the tab bar, the status bar and every
other default in a file wt owns. Zellij has no additive mechanism for this: there
is no `set-env` action, no `include`, and the `env` block in the layout zellij
serializes for resurrection is ignored.

A pane attached some other way (the session-manager plugin, the welcome screen,
plain `zellij attach`) gets no value; a shell repairs that itself from
`$ZELLIJ_SESSION_NAME`, which is the registry key, with the same call.

## State

| what             | where                               |
| ---------------- | ----------------------------------- |
| session registry | `$XDG_STATE_HOME/wt/sessions.json` |
| session marker   | `<session>/.wt/session.json`       |

The registry stores only what nothing else knows: path, title, extra ticket keys.
Members and branches are read from the filesystem and git on every call, so they
cannot go stale.

The marker is what an ancestor walk finds: it is how `cdr` and wt itself answer
"which session is this?" from inside a member — including a symlinked one, whose
resolved path leads back out to the workspace.

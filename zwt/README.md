# zwt

Feature-scoped workspaces spanning several repos: a set of worktrees inside a
mirror of the whole checkout, so every sibling path keeps resolving.

The design, and the reasoning behind it, is in [`../zwt.md`](../zwt.md). It is cut
into milestones there; this is milestone 1, the session directories. The zellij
integration and the agent dashboard are not built yet.

## Layout

```
crates/core/     registry, mirror, hydration, git, branch, drift
crates/cli/      the `zwt` binary
```

## Build

The CLI is packaged (`modules/headless/zwt.nix`), so a `home-manager switch` is
enough. For the dev loop:

```sh
cargo build            # or: nix shell nixpkgs#cargo nixpkgs#rustc --command cargo build
cargo nextest run
./tests/smoke.sh       # end-to-end against a throwaway workspace
```

## Configuration

`~/.config/zwt/config.toml`, written by hand — naming the repos zwt may touch
describes a codebase, which is not something to commit to a dotfiles repo. Nothing
about a particular workspace is compiled in either, so `workspace` is required;
every other key has a default:

```toml
workspace = "~/work"                 # the multi-repo checkout to mirror; else $ZWT_WORKSPACE
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

It is set for a whole zellij session by **attaching with it in the environment**:
panes inherit the server's environment, and the server inherits the environment of
whoever started it — on creation and on resurrection alike, since both start a
server. `zsm` does that when `zwt path --exact <name>` resolves:

```sh
WORKSPACE_ROOT="$(zwt path --exact "$session")" zellij attach --create "$session"
```

Nothing is written for zellij to read. A generated layout would work too, but a
layout — like `--config` — *replaces* what it is given rather than adding to it, so
carrying one variable would mean restating the tab bar, the status bar and every
other default in a file zwt owns. Zellij has no additive mechanism for this: there
is no `set-env` action, no `include`, and the `env` block in the layout zellij
serializes for resurrection is ignored.

A pane attached some other way (the session-manager plugin, the welcome screen,
plain `zellij attach`) gets no value; a shell repairs that itself from
`$ZELLIJ_SESSION_NAME`, which is the registry key, with the same call.

## State

| what             | where                               |
| ---------------- | ----------------------------------- |
| session registry | `$XDG_STATE_HOME/zwt/sessions.json` |
| session marker   | `<session>/.zwt/session.json`       |

The registry stores only what nothing else knows: path, title, extra ticket keys.
Members and branches are read from the filesystem and git on every call, so they
cannot go stale.

The marker is what an ancestor walk finds: it is how `cdr` and zwt itself answer
"which session is this?" from inside a member — including a symlinked one, whose
resolved path leads back out to the workspace.

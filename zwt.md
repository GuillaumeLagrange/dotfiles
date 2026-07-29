# Session based workflow — `zwt`

## Goal

Pop in and out of feature-scoped workspaces that span several CodSpeed repos.

A "session" is one unit of work in my head — usually one Linear ticket, sometimes
several, sometimes one ticket that lands as one PR per repo. It maps to: a set of
worktrees (one per involved repo) living under a single session directory, and later a
zellij session and the agents running inside it.

`zwt` is the new tool. `zsm` stays as it is (dumb attach-or-create by name, fzf picker).

## Milestones

The scope below was too wide to validate in one go, so it is cut into three layers that
each stand on their own. **Milestone 1 is a directory manager and nothing else** — no
multiplexer, no daemon, no agent state. Zellij sessions are created by hand
(`zsm <id>` / `zellij attach`) in the meantime, which is enough to use sessions daily.

| milestone                | scope                                                                              | status  |
| ------------------------ | ---------------------------------------------------------------------------------- | ------- |
| **1 — session dirs**     | mirrored session root, member selection, branch resolution, hydration, cleanup, `cdr` | current |
| **2 — zellij**           | attach, one tab per member, tab naming, cross-session tab add                       | later   |
| **3 — agent overwatch**  | Claude hooks, state files, dashboard plugin, `jump`, notifications                  | later   |

Everything already written for 2 and 3 (`crates/plugin/`, `core/{zellij,agents,jump,notify}.rs`,
`cli/cmd/{attach,agents,hook,jump}.rs`, `zsession.rs`, the `zwt-dashboard` wrapper and its
`Ctrl+b a` binding, the mako rule) is **out of the tree**; it comes back when its milestone
starts. The design notes for them are kept below, under their own headings, so nothing has
to be re-derived.

---

# Milestone 1 — session directories

The whole milestone is "a session directory exists, is correctly populated, and its
branches are managed and cleaned up". It is validated without a multiplexer.

## Layout: mirrored session root

A session directory is a **mirror of the workspace**: real worktrees for members,
symlinks to the main checkout for every other repo, plus the workspace's own dotfiles.

```
~/codspeed/sessions/cod-2931/
  .envrc                 generated: defers to the workspace's, for the flake
  .zwt/session.json      the marker that makes the directory self-describing
  .zwt/layout.kdl        generated: the zellij layout, and where WORKSPACE_ROOT is set
  platform/              real worktree      (member)
  codspeed-node/         real worktree      (member)
  docs/               -> ~/codspeed/docs    (symlink)
  codspeed/           -> ~/codspeed/codspeed
  flake/              -> ~/codspeed/flake
  ... one symlink per remaining repo
```

The symlinks exist because sibling paths are load-bearing and committed team-wide:

```
platform/.claude/settings.json:  "additionalDirectories": ["../docs", "../codspeed", "../website"]
platform/package.json:           "docs:dev": "cd ../docs && ..."
platform/AGENTS.md:88            "Other CodSpeed repositories are expected as siblings"
codspeed-rust/.envrc:            use flake ../flake#codspeed-rust
~/codspeed/.envrc:               use flake ./flake
```

The old `<repo>/.worktrees/<branch>` convention broke all of these (`../` landed in
`.worktrees/`). It goes away, along with its `ignores` entry.

Consequences that make this worth it:

- **add/remove a repo = swap symlink ↔ worktree in place.** The path never changes, so
  shell cwds, nvim sessions and Claude project dirs all stay valid.
- **`promote` is the same swap, backwards**: `git worktree remove`, `git -C <main>
switch <branch>`, restore the symlink. The session keeps working, now pointing at the
  main checkout.
- **`rm -rf <session>` is safe** — it unlinks symlinks, it does not follow them. Any
  cleanup path must preserve that property (no `find -delete`, no `rsync --delete`).

`~/codspeed/sessions/` lives inside the mirrored workspace, so mirror construction skips
non-repo entries.

## Identity and discovery

| thing | value                                                    |
| ----- | -------------------------------------------------------- |
| id    | `cod-2931` — dir name, registry key, future zellij name   |
| title | `vitest 5 compat` — registry only, shown in the picker    |
| key   | `cod-\d+` extracted from the id, used for branch matching |

Discovery is a **registry**, `~/.local/state/zwt/sessions.json`, kept deliberately thin:
it stores only what nothing else knows.

```jsonc
{
  "cod-2931": {
    "path": "~/codspeed/sessions/cod-2931",
    "title": "vitest 5 compat",
    "keys": ["COD-2931", "COD-2940"], // extra ticket keys, from `--key`
  },
}
```

Members and branches are **never** stored — they are read from `git worktree list`
(100ms for 28 repos) so they cannot go stale. The only drift possible is "path is gone",
repaired by a `stat` on read.

Placement: `default_root` config (`~/codspeed/sessions`), `--at <path>` overrides. The
registry means a session works from anywhere afterwards.

Nothing about CodSpeed is compiled into `zwt`: no repo names, no ticket prefix, no
`~/codspeed` default. Workspace, sessions root and the selectable repos all come from
`~/.config/zwt/config.toml`, which is imperative — written by hand on each machine, kept
out of this repository. A host without that file gets an error naming it, not a wrong
guess.

## Root-relative navigation: `cdr`, `cdg`, `cicr`

Two different "root" habits exist and milestone 1 separates them:

| command | root                               | definition                                                                   |
| ------- | --------------------------------- | ---------------------------------------------------------------------------- |
| `cdr`   | workspace / session root          | `cd "${WORKSPACE_ROOT:-$HOME}/$@"`                                           |
| `cdg`   | enclosing git repo (the old `cdr`) | `[ -d "$(git rev-parse --show-toplevel 2>/dev/null)" ] && cd $(git rev-parse --show-toplevel)` |

`cdg` is the plain repo-root jump — the shell alias that was `cdr` at
`modules/headless/default.nix:109` on `main`, unchanged in behaviour and renamed so `cdr`
is free for the workspace root. This branch dropped it entirely (`b19b580`, which turned
`cdc` into the workspace-root `cdr`), so **restoring it as `cdg` is milestone-1 work**.

`cdr` lives host-agnostically in `modules/headless/zsh.nix` and defaults to `$HOME`; the
codspeed module points `WORKSPACE_ROOT` at `~/codspeed`, which is what the old `cdc`
hardcoded (now removed).

Inside `cod-2931`, `cdr platform` lands in the worktree and `cdr docs` in the symlink to
the main checkout — both correct, no special-casing. Outside, it is the plain workspace.

### The session root is a property of the session, not of a directory

direnv was tried for this and is the wrong tool: it scopes the value to a directory, so
`cd ~` in a session pane unloads it and `cdr platform` lands in `~/codspeed/platform`.
Nothing directory-scoped can hold a root that has to survive leaving the directory. The
session's `.envrc` keeps only what it is good at — `source_env` of the workspace's own, so
`use flake ./flake` still reaches the session — and hydration copies member `.envrc`s
exactly as they stand, so a member behaves as it does in the main checkout.

The root comes from **the zellij session** instead, through a generated layout:

```kdl
// ~/codspeed/sessions/cod-2931/.zwt/layout.kdl
layout {
    cwd "/home/guillaume/codspeed/sessions/cod-2931"
    pane
}
env {
    WORKSPACE_ROOT "/home/guillaume/codspeed/sessions/cod-2931"
}
```

Measured on zellij 0.44.3, since the mechanism depends on it:

- panes inherit the **server** process env, including panes opened later, so the value is
  cwd-independent for the session's whole life;
- an `env` block works in a layout as well as in `config.kdl`, and a layout's config
  section is additive — `~/.config/zellij/config.kdl` still loads, unlike `--config`,
  which would replace it (zellij has no include);
- `--layout` applies the block when **creating** a session *and* when resurrecting one,
  which is what makes it survive a reboot;
- nothing else does: there is no `set-env` action, and an `env` block in the layout zellij
  serializes for resurrection is ignored. Zellij stores no per-session environment.

So the layout has to be passed on every attach, which `zsm` does when `zwt path --exact
--layout <name>` resolves. Attaching any other way — the session-manager plugin, the
welcome screen, plain `zellij attach` — starts a server that never saw the value, and the
shell repairs it: `$ZELLIJ_SESSION_NAME` is the registry key, so `zwt path --exact` on it
gives the root (`modules/headless/zsh.nix`). No tabs or panes are described in the layout:
naming the members there would make `add` and `promote` rewrite it, and splits are not
zwt's to decide.

Below the session, `cdr` resolves its root in this order — the walk comes first so that a
bare terminal, or a pane of some other session, that `cd`s into a session directory still
gets it right:

1. nearest ancestor of the **logical** `$PWD` containing `.zwt/session.json`
   (zsh keeps the logical path when `cd`-ing through a symlink, so this works inside
   `<session>/docs` even though the real path is elsewhere)
2. `$WORKSPACE_ROOT` — the session's, in one of its panes; else the workspace, from
   `home.sessionVariables`
3. `$HOME`

So the marker file `<session>/.zwt/session.json` is part of the session layout: it is
what makes a session self-describing without any registry lookup or env var.

```jsonc
{ "id": "cod-2931", "workspace": "/home/guillaume/codspeed" }
```

`zwt` itself resolves "the session I am in" the same way, preferring `$PWD` over the
resolved cwd whenever the two still describe the same directory. That is what makes
`zwt path`, `zwt add` and `zwt sync` work from inside a symlinked member.

## Member selection

`zwt new <session-name>` shows an fzf multi-select over the **pre-approved repo list**,
not over everything in `~/codspeed` — forks, vendored trees and scratch checkouts never
show up.

That list is `repos` in `~/.config/zwt/config.toml`, which is written **by hand** and
deliberately not generated by home-manager: naming the repos describes CodSpeed's
codebase, and this repository is public. The same file carries `workspace` and
`default_root`.

Non-selected repos become symlinks; `zwt add <repo>` swaps one for a worktree later, on
the same terms as if it had been picked. Picking nothing is valid: the session is then a
complete mirror, ready to `zwt add` into.

## No branch management

Members are checked out **detached**, at their own main branch. Deciding a branch name at
creation time was the rigid part: the ticket may not exist yet, one repo may want two
branches, another may end up with none. `git switch -c` inside the worktree is a better
answer than anything zwt could guess, and `zwt promote` is there for when a worktree does
have a branch worth handing to the main checkout.

"Its own main branch" is resolved per repo, because it is `staging` in one and `master` in
the next: `origin/HEAD`, else a `GIT_MAIN_BRANCH` that actually resolves _there_ (direnv
exports it for whichever repo the shell stands in, so it cannot be trusted across repos),
else whichever of `main`/`master`/`staging`/`trunk`/`develop` exists. The fork point is
`origin/<base>` when it exists, so a worktree never starts behind the remote.

## Hydration

`.envrc`, `**/.env`, `**/.claude/settings.local.json`, `.nvim.lua`, `.taplo.toml` are all
globally gitignored, so `git worktree add` brings none of them — a fresh worktree has no
`.envrc` at all, and the whole flake/direnv env is silently missing there.

```
git worktree add --detach <path> <base>
git -C <main> status --porcelain --ignored=matching -uall | grep '^!!'
  keep what `hydrate` names
  cp -a --reflink=auto -> worktree
direnv allow <path>
```

That is the whole of it. The copies are verbatim: nothing is rewritten, so a member's
environment is the main checkout's, which is the least surprising thing it can be.

The list is `hydrate` in `~/.config/zwt/config.toml`, on the same grounds as `repos`:
which ignored files a worktree cannot work without describes a codebase, and mine is not
this repository's business. Patterns read like gitignore's — a bare name matches at any
depth, one with a `/` from the repo root, `*` within a single name — and the default is
the five above, so a config that says nothing behaves as before.

Installed dependencies and generated code are **not** copied: they are the repo's own
`post-checkout` hook's business, per repo, and a hook that installs its own `node_modules`
is both more correct and less surprising than reflinking someone else's. Editor and tool
**state** is excluded on the same grounds but for a sharper reason — a `Session.vim`
records a cwd and absolute paths, so a copied one restores the checkout it was written in
and quietly drags the worktree back to the main one.

(Reflinking the whole ignored tree does work — measured on this btrfs `/home`,
`node_modules` 2.8G in 8.9s and `target/` 24G in 3.8s, both 0 bytes extra. It is one
function if it ever comes back, and would need the `df` guard: three sessions that each
rebuild `target/` is 72G of real disk.)

## Cleanup and drift

`zwt rm <id>` is the guarded teardown, and it is the half of the milestone that must not
lose work. Per member worktree, refuse (unless `--force`) on: dirty tree, untracked
files, unpushed commits, stashes. Then `git worktree remove`, delete the local branch if
it is merged and has no upstream, unlink symlinks (never follow), drop the registry
entry.

`zwt sync` reports drift, `zwt sync --fix` repairs it: stale mirror symlinks (repos
cloned or removed since creation), un-allowed direnv, an `.envrc` that is missing or no
longer what zwt generates, a missing marker, a layout that is missing or no longer points
`WORKSPACE_ROOT` at this session, worktrees deleted by hand, branches no longer matching
the key.

## CLI surface (milestone 1)

```
zwt new <branch|id>       scan, pick members, worktrees + mirror + hydrate
zwt add <repo> [branch]   symlink -> worktree, hydrate
zwt promote <repo>        worktree -> symlink, main checkout switches to the branch
zwt rm [<id>]             guarded teardown (dirty tree / unpushed / stashes; --force)
zwt ls                    sessions, members, branches
zwt path [<id>]           the session root, for shell use (`cd "$(zwt path cod-2931)"`)
  --layout                  the zellij layout to attach with instead
  --exact                   the id as given, not as a prefix: for a name that came
                            from elsewhere, where the nearest session is wrong
zwt sync [--fix]          drift report / repair
```

No `attach`, no picker-that-attaches: `zwt` with no argument prints the fzf picker's
choice as a path (milestone 2 turns that into an attach).

## Validation checklist

- [ ] `zwt new cod-2931-…` with two members: worktrees real, every other repo a symlink,
      `.envrc` + `.zwt/session.json` + `.zwt/layout.kdl` present, direnv allowed.
- [ ] `zsm cod-2931`: `WORKSPACE_ROOT` is the session in every pane, `cdr docs` lands in
      the symlink, `cdr platform` in the worktree, `cdg` jumps to the enclosing repo root.
- [ ] `cd ~`, then `cdr platform`: still the session's, not `~/codspeed`'s. Same in a pane
      opened afterwards, and after the zellij server is killed and the session reattached.
- [ ] `zellij attach cod-2931` without a layout: the shell repairs `WORKSPACE_ROOT` from
      `$ZELLIJ_SESSION_NAME` anyway.
- [ ] `cicr` / `cicc` / `cieh` / `cicm` inside the session build from the session's repos.
- [ ] `platform`'s `../docs`, `../codspeed` paths and `pnpm docs:dev` resolve.
- [ ] hydration: `node_modules`, `target/`, `.venv`, `.env` present; `du` of the session
      is ~0 against the main checkout.
- [ ] `zwt add codspeed` swaps a symlink for a worktree in place, path unchanged.
- [ ] `zwt promote platform` swaps back and leaves the main checkout on the branch.
- [ ] `zwt rm` refuses on a dirty tree, unpushed commits and a stash; `--force` proceeds.
- [ ] after `zwt rm`, `~/codspeed/<repo>` is intact — no symlink was followed.
- [ ] `zwt sync` sees a hand-deleted worktree and a repo cloned after creation, `--fix`
      repairs both.

---

# Milestone 2 — zellij (later)

One tab per member repo, named after the repo, cwd set. **No layout opinion** — splits
are mine to make.

```
zellij action new-tab --cwd <session>/<repo> --name <repo>
```

Works cross-session (`zellij --session X action ...`), so `zwt add` can add a tab to a
detached session.

- `zwt <id>` attaches, creating the zellij session and its tabs if absent. Attach never
  mutates the session directory, and always passes `--layout <session>/.zwt/layout.kdl`,
  which is what carries `WORKSPACE_ROOT` (milestone 1) — it takes over `zsm`'s job of
  finding that file.
- `ZELLIJ_SESSION_NAME` == id, so panes self-identify — the join key milestone 3 needs.
- Whether the tabs belong in `layout.kdl` rather than in `new-tab` calls is the open
  question: putting them there means `add` and `promote` have to rewrite it, and zellij's
  own serialized layout wins for tabs on a resurrect anyway.
- The chpwd auto-rename hook goes away — it would clobber the tab names. Renaming becomes
  manual on `Ctrl+b → n` (`modules/headless/zellij.nix:106-123`).
- `zwt sync` gains "missing tabs" to its drift list.

---

# Milestone 3 — agent overwatch (later)

A dashboard over every running Claude process — grouped by session, showing repo and
branch, able to jump to the exact pane, whether the agent runs in a zellij pane directly
or inside nvim's sidekick.

## Dashboard: zellij plugin + state files

The plugin is **pure UI**. Agent state lives in files so that mako, the CLI, or a future
bar badge can read the same truth.

```
Claude hook (SessionStart|UserPromptSubmit|PostToolUse|Notification|Stop)
  -> $XDG_RUNTIME_DIR/zwt/agents/<claude_session_id>.json
     { state, zellij_session, pane_id, cwd, nvim_sock, pid, repo, branch, ts }
  -> zellij pipe --name zwt-refresh          (nudge, best effort)

plugin: set_timeout(2s) + pipe -> run_command("zwt agents --json")
jump:   run_command("zwt jump <id>")         ONE implementation, shared with mako
```

Claude inherits `ZELLIJ_SESSION_NAME`, `ZELLIJ_PANE_ID` and `$NVIM` even when nested
inside nvim, so an agent is fully addressable by its own environment.

## Jump: one window per session

```
zwt jump <agent>
  client = pgrep -f 'zellij attach.*S'
  if client:  walk ppid chain -> kitty pid -> niri window id -> focus-window --id
  else:       kitty -e zellij attach S
  zellij --session S action go-to-tab-by-id <T>
  zellij --session S action focus-pane-id <P>
  if nvim_sock: nvim --server <sock> --remote-expr  (focus sidekick)
```

Converges on one kitty window per active session, and never drags the session I'm
currently in somewhere else.

## Notifications

Today's hook says _"Session in platform needs attention"_ — under the mirror layout
`basename $CLAUDE_PROJECT_DIR` is just the repo name, identical in every session.

```
hook Notification:
  if niri focused window hosts session S AND pane P is_focused -> exit 0
  notify-send --app-name=zwt \
    -h string:x-canonical-private-synchronous:zwt-<agent> \
    -A default=Jump "cod-2931 / codspeed-node" "waiting for input"
  (backgrounded; action 'default' -> zwt jump <agent>)

mako: "app-name=zwt" { on-button-left=invoke-default-action }
Stop -> urgency=low, or off entirely
```

Don't notify about the pane I'm staring at, one replaceable notification per agent, click
to jump. The existing `do-not-disturb` mako mode already suppresses these.

## CLI surface added by 2 and 3

```
zwt                       fzf picker over sessions -> attach          (2)
zwt <id>                  attach, create zellij session + tabs        (2)
zwt jump <agent>          the one jump implementation                 (3)
zwt agents [--json]       state for the plugin, mako, anything else   (3)
zwt hook <event>          what Claude's hooks call                    (3)
```

---

## Implementation

Rust workspace at `~/dotfiles/zwt/` (root level, like `nvim/`), built with cargo for now
— nix packaging comes later.

```
zwt/
  crates/core/     registry, mirror, hydrate, git, branch, drift        (1)
  crates/cli/      zwt
  crates/plugin/   wasm32-wasip1, zellij-tile                           (3)
```

One schema, defined once, shared by the CLI and the plugin.

Milestone 1 keeps `zwt`'s runtime PATH down to `coreutils direnv fzf git` — no zellij, no
niri, no notify-send. It never runs zellij itself: it generates the layout and prints its
path, and `zsm` (later `zwt <id>`) is what attaches with it. The one thing reading
`ZELLIJ_SESSION_NAME` is the zsh init, which resolves it through `zwt path --exact`.

## Verified primitives

Everything here was checked on this machine (zellij 0.44.3, niri, kitty). Milestone 1 uses
only the layout `env` block (above); the rest is recorded for 2 and 3.

```
zellij --session X action list-panes --all --json    # id, tab_id, tab_name, is_focused
zellij --session X action dump-layout                # per-pane cwd
zellij --session X action new-tab --cwd --name [--layout-string KDL]
zellij --session X action go-to-tab-by-id | focus-pane-id
zellij pipe --name <n> [--plugin file:...]           # launches the plugin if not running

niri msg -j windows                                  # includes pid per window
niri msg action focus-window --id <W>

zellij-tile: switch_session_with_focus(name, tab, pane_id), focus_pane_with_id,
             get_pane_cwd, run_command, scan_host_folder, set_timeout, web_request
SessionInfo: { name, tabs, panes: PaneManifest, connected_clients, is_current_session }
             delivered for ALL sessions via SessionUpdate
PaneInfo:    has terminal_command; has NO cwd and NO pid (use get_pane_cwd)

in-pane env: ZELLIJ_SESSION_NAME, ZELLIJ_PANE_ID, NVIM   (inherited through nvim)
window title: "<zellij session> | <pane title>"          (fallback for pid archaeology)
```

## Open items

- **Disk guard** for reflink divergence: warn below some `df` threshold, `--no-seed`. (1)
- **Migrations**: move `platform/.worktrees/{cod-3036,cod-3010-...}` into sessions, drop
  `.worktrees` from `ignores` (`modules/headless/default.nix:206`). (1)
- **Panes with no zellij session at all** — a bare kitty window, or ssh — get the
  workspace, not a session. The marker walk covers them once they `cd` in, which may be
  all that is wanted. (1)
- **wasm32-wasip1 in nixpkgs' rustc** — unresolved, only matters once nix packaging lands.
  rustup covers the dev loop (`rustup target add wasm32-wasip1`). (3)
- **Does a `Run` keybind's pane inherit the _focused_ pane's cwd?** The manual tab rename
  depends on it. If not, read the cwd from `dump-layout` instead of `$PWD`. (2)
- **gullywash**: CLI only. No plugin, no niri, no notifications.
- **Multi-machine sessions** are out of scope — the registry is per-machine, and branches
  are the thing that syncs.

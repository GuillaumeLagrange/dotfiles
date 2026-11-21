# launcher

The daemon behind the bar's launcher panel (`modules/desktop/quickshell/qml/popups/Launcher.qml`):
the sources, the fzf-style matching, the clipboard history and every action. The panel only draws
what the daemon sends and forwards keys as requests. One process per session, the `launcher`
user service, listening on `$XDG_RUNTIME_DIR/launcher.sock`.

A cargo workspace, one crate per group of modes, so each builds and tests on its own:

```
crates/core/       the wire (protocol.rs), the engine (engine.rs: the actor owning sources and
                   panel sessions), the socket (server.rs), matching (matcher.rs), the Source
                   contract and Ctx (source.rs), frecency, the config, niri and notifications,
                   the clipboard handle sources copy through, and a test context (testing.rs)
crates/daemon/     the `launcher` binary: `daemon`, and `query`/`activate`, clients of the
                   socket for tests and debugging
crates/clipboard/  the Wayland watcher and server of the selection, the history store and mode
crates/desktop/    apps, windows, emoji
crates/browser/    Firefox tabs (TabCtl over D-Bus) and bookmarks
crates/passwords/  Proton Pass and 1Password
crates/dev/        zellij sessions, PRs, files
```

Frecency (picks per entry, halving every two weeks) is kept in
`$XDG_STATE_HOME/launcher/frecency.json`.

## Modes

| Mode | Name | Short | Entries |
|---|---|---|---|
| Apps | `apps` | `a` | desktop entries that are not NoDisplay |
| Windows | `windows` | `w` | niri's windows, most recently focused first |
| Emoji | `emoji` | `e` | emoji-test.txt, named and keyworded by CLDR annotations |
| Clipboard | `clipboard` | `c` | the history, pinned first, then newest first |
| Browser | `browser` | `b` | Firefox's open tabs (TabCtl), then its bookmarks |
| Passwords | `passwords` | `p` | Proton Pass (`pass-cli`) and 1Password (`op`) items |
| Sessions | `sessions` | `s` | zellij sessions, live and resurrectable, in zellij-sessions' order |
| Reviews | `reviews` | `r` | the PRs of `reviews --json`, by tab |
| Files | `files` | `f` | files under the configured roots, .gitignore respected |

A mode the config disables is left out of `hello` and refuses `open`.

## Protocol

Newline-delimited JSON over the socket, one object per line, both ways. The panel connects once
and keeps the connection; it may reconnect at any time and starts over with `open`.

On connect the daemon sends:

```json
{"type":"hello","modes":[{"mode":"apps","short":"a","title":"Apps","glyph":"apps"}, …]}
```

`glyph` is a key of the bar's `Config.glyph`.

Requests (`op`):

```json
{"op":"open","mode":"apps"}                         // also switches mode; resets the query
{"op":"query","text":"fire","seq":12}               // seq echoes back in results
{"op":"activate","id":"firefox.desktop","action":"open"}   // action omitted: the default one
{"op":"preview","id":"c:42"}
{"op":"close"}                                      // the panel hid
```

Events (`type`):

```json
{"type":"results","seq":12,"mode":"apps","query":"fire","total":3,"status":null,"items":[Item…]}
{"type":"preview","id":"c:42","preview":Preview}
{"type":"working","text":"Copying the password…"}  // an activation runs on: wait for its done or error
{"type":"done","close":true}                        // an activation finished: close the panel or stay
{"type":"switch","mode":"clipboard"}                // the panel switches mode (a `/` row was picked)
{"type":"error","message":"…"}
```

`results` is also sent unprompted, with the last `seq`, whenever the open mode's entries change
(a window opened, tabs changed, the password list arrived, files are still being walked).

An `Item`:

```json
{
  "id": "firefox.desktop",
  "title": "Firefox",
  "subtitle": "Web Browser",
  "hl": [[0, 2]],                 // title ranges matched, UTF-16 offsets, end exclusive
  "shl": [],                      // the same for the subtitle
  "icon": {"kind": "name", "value": "firefox"},
  "accessory": "",                // right-aligned, faint
  "color": null,                  // a dot before the title, "#rrggbb"
  "section": "",                  // heading the row sits under; only sent for an empty query
  "actions": [{"id": "open", "label": "Open", "key": "Return"}, …],
  "preview": false                // whether `preview` has something for it
}
```

The first action is Enter's. `key` names the panel's binding: `Return`, `Alt+Return`,
`Ctrl+Return`, `Shift+Delete`, `Ctrl+R`, or none (actions menu only, Ctrl+K).

`icon.kind` is `name` (an icon theme name, resolved by the panel), `path` (an absolute file),
`url` (http(s) or data:), `emoji` (the text itself), `glyph` (a `Config.glyph` key) or `none`.

`status` is a line above the results: `{"kind":"loading"|"info"|"error","text":"…"}`, e.g.
"Loading 1Password…" or "No open tabs: TabCtl is not connected (…)".

A `Preview` is `{"kind":"text","text":"…","mono":true}`, `{"kind":"image","path":"/…"}` or
`{"kind":"fields","fields":[["Username","bob"],["URL","https://…"]]}`.

A query starting with `/` lists the modes instead (rows with id `mode:<name>`); activating one
answers `switch`. The panel also switches by itself on `/name ` or `/short ` (with the space).

## Matching

nucleo-matcher, the fzf-compatible matcher from helix: fzf's query syntax (`'exact`, `^prefix`,
`suffix$`, `!not`, space-separated terms), smart case, Unicode normalisation. Each entry is
matched on its title; one the title misses is matched on title, subtitle and keywords together,
at 0.7 of the score, so a term can hit any field. The score is multiplied by the entry's `boost`
(open tabs 1.5 over bookmarks) and gets a bounded frecency bonus. An empty query keeps the
source's order, frecency first where the source has any. Highlight ranges are computed for the
rows sent only (at most 100).

## Sources

A source implements `Source` (`core/src/source.rs`). The engine calls it on its own thread, so every
method returns quickly: anything slow (a process, the network, a walk) runs on a thread the
source spawns, which updates the source's shared state and calls `ctx.updated(mode)`. Entries
are handed over as an `Arc<Vec<Entry>>`; the engine re-prepares its haystacks when the pointer
changes, so a source replaces the whole vector rather than mutating it.

`activate` returns at once too. Slow work whose result the user acts on next (a password
copied, then pasted) is returned as `Outcome::Wait { status, work }`: the engine runs it on a
thread, the panel shows `status` and takes no key but Escape until the `done` or `error` its end
sends. An end the panel no longer waits for (it closed, or opened a mode since) sends nothing; a
failure then is a notification. Other work that outlives `activate` (a session restarted)
reports a failure with `ctx.notify`.

A program handed to niri (`ctx.spawn`) is first resolved on the daemon's own `PATH`, which its
Nix wrapper sets, so what a pick runs never depends on the session's `PATH`.

- Apps: desktop entries of `$XDG_DATA_HOME` then `$XDG_DATA_DIRS`, parsed by hand
  (`desktop/src/entry.rs`): field codes, the spec's quoting, `Terminal=`, `Path=` (`env -C`),
  `OnlyShowIn`/`NotShowIn` against `$XDG_CURRENT_DESKTOP`, desktop actions as extra actions.
- Windows: `niri msg --json windows`, most recently focused first, the focused one last.
- Emoji: `emoji-test.txt` (fully-qualified, no skin-tone variants) and CLDR's annotation files,
  read one `<annotation>` per line as CLDR lays them out.
- Browser: TabCtl's D-Bus instances (`dev.slastra.TabCtl.Firefox`, `…Firefox2`, one per
  profile), re-pulled on `TabsUpdated`; switching a tab then focuses the Firefox window whose
  title starts with the tab's, since Wayland compositors ignore Firefox's own request. Bookmarks
  from a copy of each profile's `places.sqlite` (and its WAL), refreshed when one changed.
- Passwords: `pass-cli` lists summaries only (title, vault, type); usernames, URLs and whether a
  login has a TOTP come with `--show-secrets`, which loads every password and marks every item
  read, so Proton rows show their vault and offer the one-time code on every login (a failure
  shows in the panel). `op` lists usernames and URLs. A fetch takes over a second (pass-cli
  syncs), hence `Outcome::Wait`. Ids are passed as `--share-id=…`: Proton's base64url ids can
  start with `-`, which clap takes for a flag.
- Sessions: two `zellij list-sessions` merged (one listing can leave a live session out), in
  zellij-sessions' order, with its colours.
- Files: `ignore`'s parallel walker, published in batches, kept 5 minutes, dropped 10 minutes
  after the panel left the mode.

## Config

`$XDG_CONFIG_HOME/launcher/config.json`, written by `modules/desktop/launcher.nix`: `terminal`
(the argv prefix of a terminal window) and `modes`, one key per enabled mode:

| Mode | Section |
|---|---|
| `apps`, `windows`, `sessions` | `null` |
| `emoji` | `emoji_test`, `annotations` (paths) |
| `clipboard` | `max_entries`, `max_age_days`, `max_text_bytes`, `max_image_bytes`, `secret_clear_seconds` |
| `browser` | `profiles_ini` (paths, `~/` expanded), `firefox` (command) |
| `passwords` | `proton`, `onepassword`: `{"command": …}` or `null` |
| `reviews` | `command` (the `reviews` binary) |
| `files` | `roots`, `exclude` (paths relative to a root), `max` |

## Clipboard

The daemon is the clipboard manager: it watches the selection through `ext-data-control-v1`,
records what is copied, and serves the selection itself when an entry is picked. Serving it from
a process that stays up is what makes a pick stick; a launcher that set the selection from its
own window lost it when the window closed, and the pick had to be made twice.

- Text, `text/uri-list` and images (png, jpeg, webp, gif) are kept, up to the configured sizes.
- An offer carrying `x-kde-passwordManagerHint: secret` is not recorded (1Password and KeePassXC
  set it; the daemon's own secrets carry it too).
- Copying the same content again moves its entry to the top.
- The history is `$XDG_DATA_HOME/launcher/clipboard/history.json` plus one file per image; at most
  `max_entries` unpinned entries, none older than `max_age_days` unless pinned, pruned on every
  write and daily.
- A secret the daemon copies (a password) is cleared after `secret_clear_seconds`, unless the
  selection changed hands meanwhile.
- Without a compositor connection the daemon does not start, and losing it later exits the
  daemon: the unit restarts it against the compositor there is then.

## Tests

`cargo nextest run`, also in the package's build. Each source is tested on fixtures (desktop
entries, emoji data, a places.sqlite built in the test, stub `pass-cli`, `op`, `zellij` and
`niri` binaries on `PATH`, a private D-Bus bus for TabCtl). The clipboard and the daemon itself
(`daemon/tests/daemon.rs`: the binary driven through its socket by `launcher query` and
`launcher activate`) run against a private headless sway (`WLR_BACKENDS=headless`,
`WLR_RENDERER=pixman`, its own `XDG_RUNTIME_DIR`, no session bus, a config of its own so it
imports nothing into the user's systemd manager), driven with wl-copy and wl-paste. The panel is
tested by the bar's suite (`modules/desktop/quickshell/tests/tests/launcher.rs`) against a stub
daemon.

nixpkgs' cargo hook sets `LIBSQLITE3_SYS_USE_PKG_CONFIG`, so the package links nixpkgs' sqlite;
cargo outside Nix builds rusqlite's bundled copy.

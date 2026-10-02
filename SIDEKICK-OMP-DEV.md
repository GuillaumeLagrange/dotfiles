# Sidekick ↔ omp bridge (temporary dev notes — delete when done)

Goal: `<leader>aa` either attaches to an omp TUI already running in a zellij pane, or
opens a fresh omp in a new zellij pane and attaches to it. No omp runs in an nvim
terminal. `<leader>at` (`{this}`) must work in both cases. Terminal-injection
discovery is unusable under zellij (`list-panes` gives no cwd/pid), so attach goes
through a socket exposed by omp itself.

## Pieces

- `ai/omp/extensions/nvim-bridge.ts` — omp extension. Every interactive session
  listens on `~/.omp/run/nvim-bridge/<pid>.sock` and writes `<pid>.json`
  (`pid`, `cwd`, `socket`, `zellij` session name). NDJSON ops: `{"op":"send","text":…}` → `ui.pasteToEditor`
  (prefixing a newline when the composer sits mid-line) then focus this omp's zellij
  pane (`zellij action focus-pane-id`, from the `ZELLIJ_*` env of the shell that
  launched it; no-op outside zellij); `{"op":"submit"}` → submit composer via
  `pi.sendUserMessage`. All ops run through one server-wide promise queue, so `send`
  and `submit` can't overlap.
- `ai/omp/nvim-bridge.test.ts` — vitest over the socket protocol; `cd ai/omp && npm test`.
  Outside `extensions/` because omp loads every `.ts` there as an extension.
- `modules/headless/ai.nix` — symlinks `ai/omp/extensions` → `~/.omp/agent/extensions`.
- `nvim/lua/sidekick-omp/init.lua` — sidekick session backend `omp`: `sessions()` reads
  the descriptor dir (dropping dead pids), sessions are `external = true` (no nvim
  terminal), `send`/`submit` write to the socket, `mux_session` = zellij session so the
  picker shows `[omp:<session>]`. Tests: `cd nvim/lua/sidekick-omp &&
  just test` (plenary busted, same harness as `agent-diff`).
- New sessions: `setup()` sets `cli.mux = { enabled = true, backend = 'omp' }`, so
  sidekick creates them through this backend. `M:start()` runs `zellij action new-pane
  --close-on-exit --cwd <cwd> -- omp`, keeps a placeholder attached (ops issued meanwhile
  are queued), then polls for a new descriptor in that cwd, attaches it and replays the
  queue.
- `nvim/plugin/ai.lua` — `require('sidekick-omp').setup()`, and `Config.cli.tools` is
  replaced by a single `omp` entry so the CLI picker only appears when an omp is
  already running elsewhere (one candidate auto-attaches).

## Status

- [x] Extension written, `vitest` suite in `ai/omp` (`cd ai/omp && npm test`)
- [x] nix symlink
- [x] nvim backend + wiring
- [x] Verified: socket + descriptor appear for a running omp TUI, removed on shutdown
- [x] Verified: `{"op":"send"}` lands in the composer
- [x] Verified: headless nvim lists `omp: <pid>` (backend `omp`, external) and its
      `send` reaches that composer
- [x] Verified: send into an omp started in a zellij pane focuses that pane
- [x] Verified: spawning from nvim opens an omp pane in the current zellij session,
      attaches it, and a `send` issued before it registered lands in its composer
- [x] Picker shows `[omp:<zellij session>]` for omps started after the extension change

## Notes

- Extension needs `~/.omp/agent/extensions` symlink; created by home-manager activation
  (`home.activation.aiLinks`), linked by hand during dev.
- Socket callbacks must not throw: an uncaught throw kills the omp session.
- Ordering: nvim opens one connection per op, so the extension keeps a single
  server-wide promise queue. The `serializes a slow send…` test fails if it goes.
- `ctx.shutdown()` does not exit the process — the TUI kept running; SIGTERM exits
  cleanly and removes the descriptor.

# Sidekick ↔ omp bridge (temporary dev notes — delete when done)

Goal: `<leader>aa` toggles either a fresh omp in an nvim terminal, or attaches to an
omp TUI already running elsewhere (zellij pane). `<leader>at` (`{this}`) must work in
both cases. Terminal-injection discovery is unusable under zellij (`list-panes` gives
no cwd/pid), so attach goes through a socket exposed by omp itself.

## Pieces

- `ai/omp/extensions/nvim-bridge.ts` — omp extension. Every interactive session
  listens on `~/.omp/run/nvim-bridge/<pid>.sock` and writes `<pid>.json`
  (`pid`, `cwd`, `socket`). NDJSON ops: `{"op":"send","text":…}` → `ui.pasteToEditor`
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
  terminal), `send`/`submit` write to the socket. Tests: `cd nvim/lua/sidekick-omp &&
  just test` (plenary busted, same harness as `agent-diff`).
- `nvim/plugin/ai.lua` — `require('sidekick-omp').setup()`.
- `M.move()` (`<leader>am`) — handoff: SIGTERM the omp
  holding the attached session, wait for the process to go, then start
  `omp --resume <id>` on the other side (nvim terminal ↔ zellij pane). The session
  stays attached: ejecting to a pane polls for the new descriptor and attaches it.

New sessions keep sidekick's default path (`cli.mux.enabled = false` → nvim terminal).

## Status

- [x] Extension written, `vitest` suite in `ai/omp` (`cd ai/omp && npm test`)
- [x] nix symlink
- [x] nvim backend + wiring
- [x] Verified: socket + descriptor appear for a running omp TUI, removed on shutdown
- [x] Verified: `{"op":"send"}` lands in the composer
- [x] Verified: headless nvim lists `omp: <pid>` (backend `omp`, external) and its
      `send` reaches that composer
- [x] Verified: send into an omp started in a zellij pane focuses that pane
- [ ] Try it live: `<leader>aa` should offer the running omp next to a fresh in-nvim
      one, `<leader>at` should reach it
- [x] Feature 2: round trip verified live — pane omp with a "MANGO" turn moved into
      an nvim terminal with its transcript, then back out to a zellij pane, same
      session id throughout

## Notes

- Extension needs `~/.omp/agent/extensions` symlink; created by home-manager activation
  (`home.activation.aiLinks`), linked by hand during dev.
- Socket callbacks must not throw: an uncaught throw kills the omp session.
- Ordering: nvim opens one connection per op, so the extension keeps a single
  server-wide promise queue. The `serializes a slow send…` test fails if it goes.
- `ctx.shutdown()` does not exit the process — the TUI kept running. The handoff
  uses SIGTERM instead, which exits cleanly and removes the descriptor.
- `omp --resume <id>` errors out on a session with no file on disk, and the file
  only appears on the first turn, so a handoff before that starts a plain `omp`.

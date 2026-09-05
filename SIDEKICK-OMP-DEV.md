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
- `nvim/lua/sidekick-omp.lua` — sidekick session backend `omp`: `sessions()` reads the
  descriptor dir (dropping dead pids), sessions are `external = true` (no nvim terminal),
  `send`/`submit` write to the socket.
- `nvim/plugin/ai.lua` — `require('sidekick-omp').setup()`.

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
- [ ] Feature 2 (move a session between nvim window and zellij pane) — not started,
      blocked on Feature 1

## Notes

- Extension needs `~/.omp/agent/extensions` symlink; created by home-manager activation
  (`home.activation.aiLinks`), linked by hand during dev.
- Socket callbacks must not throw: an uncaught throw kills the omp session.
- Ordering: nvim opens one connection per op, so the extension keeps a single
  server-wide promise queue. The `serializes a slow send…` test fails if it goes.

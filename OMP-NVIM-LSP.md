# omp ↔ nvim LSP (dev notes — delete when done)

Branch: `omp-nvim-lsp`. Goal: omp never runs a language server of its own. Its `lsp` tool, and the
diagnostics after an edit, are served by the LSP clients of an nvim working on the same project.
nvim stays the authority on which servers run and how (rustaceanvim for rust, lspconfig `ts_ls`).

## Decisions

1. **No nvim, no LSP.** `lsp.enabled: false` stays in `ai/omp/config.yml`. The `lsp` tool is always
   registered (stable tool list, no prompt-cache churn) and answers "no nvim attached" when no nvim
   serves the file. No fallback to omp's own servers.
2. **Transport = nvim-bridge socket.** nvim already talks NDJSON to `~/.omp/run/nvim-bridge/<pid>.sock`.
   nvim opens one persistent connection per omp and registers as an LSP provider
   (`{"op":"lsp_provide",...}`); omp then sends requests on it (`{"id":n,"method":...,"params":...}`)
   and nvim answers asynchronously (`{"id":n,"result"|"error":...}`). JSON only: no msgpack, no npm
   dependency, no `--remote-expr` (which blocks nvim's main loop).
3. **nvim stays fluid.** Every nvim-side handler is callback-driven (libuv pipe + `vim.schedule` +
   `client:request` callbacks). No `vim.wait`, no `request_sync`.
4. **Buffer sync after omp edits.** After a mutating omp tool (edit/write/ast_edit/bash…), omp asks
   nvim to `checktime` loaded buffers whose file changed on disk, *only if the buffer is unmodified*.
   Modified buffers are left alone: nvim's own W12/conflict handling applies when the user gets back
   to them. Answers computed against a modified buffer say so.
5. **Files not loaded in nvim.** Load just that file into a hidden, unlisted, `noswapfile` buffer so
   nvim's normal FileType → attach path (rustaceanvim, `vim.lsp.enable`) runs. Only files a request
   names, never a workspace sweep. Wiped after an idle TTL unless the user opened it meanwhile.
6. **Pairing.** (proposed, to confirm) nvim connects to every live omp whose cwd overlaps its own cwd.
   omp routes a request to the connected nvim whose cwd contains the file (longest prefix wins).

## Diagnostics freshness (decided)

Only LSP-standard mechanisms, nothing server-specific (no flycheck, no tsserver commands):

- **Mirror `:w`.** When omp changes a file, nvim reloads the buffer (if unmodified) and sends
  `textDocument/didSave` to its clients, exactly what `:w` sends. rust-analyzer then runs its
  check-on-save (clippy) like for a manual save; other servers do whatever they do on save.
- **No spam.** didSave is coalesced per buffer with a short trailing debounce: a burst of omp edits
  is one save, like a user saving once after several changes.
- **"Fresh" =** pull (`textDocument/diagnostic`, LSP 3.17) answered for clients that support it,
  no `$/progress` work in flight on the buffer's clients (covers indexing and RA's check), and no
  `publishDiagnostics` for the file during a quiet window (push-only servers such as ts_ls), all
  bounded by a budget. Out of budget → return what nvim has, plus the titles of the progress still
  running. Read from `vim.diagnostic.get(buf)`: exactly what nvim shows.

## Open questions

- Pairing (decision 6) is my default, not confirmed.
- Subagents: `ctx.agent.kind === "sub"` suggests they run in-process, in which case they share the
  module-level provider set in `lsp.ts` and get LSP for free. Not verified with a real `task` run.
- Edit budget is 10 s (`OMP_NVIM_LSP_EDIT_BUDGET_MS`). A cold `cargo clippy` on a big workspace
  exceeds it: the result then says which progress was still running.
- The ts_ls quiet window (600 ms, at least 1 s for push-only servers) is a heuristic: no version on
  its publishes. Held up on platform's `packages/api` (1.2 s per edit once the project is loaded).

## Test bed

- `/tmp/omp-lsp-platform`: detached `git worktree` of `~/codspeed/platform` (chunky rust + TS) for
  manual runs, env from `nix develop ~/codspeed/flake` (typescript-language-server), node 24.21
  through fnm. Remove with `git -C ~/codspeed/platform worktree remove /tmp/omp-lsp-platform`.

## E2E harness

`ai/omp/nvim-lsp.e2e.test.ts`, `just test-omp-e2e` (~15 s). Isolated: a throwaway headless nvim
with the *real* config from this checkout (`XDG_CONFIG_HOME` → tmp dir linking `nvim` →
`dotfiles/nvim`), private `XDG_STATE_HOME` / `XDG_CACHE_HOME`, real `XDG_DATA_HOME` (plugins), its
own `OMP_NVIM_BRIDGE_DIR`, fixtures in a tmp dir (cargo project, TS project),
typescript-language-server from nixpkgs. Never touches the user's running nvims or omps.

## Plan / status

- [x] Branch, this doc
- [x] E2E harness
- [x] Probe LSP diagnostic behavior (rust-analyzer, ts_ls) → freshness strategy
- [x] Bridge protocol (omp side): `extensions/nvim-bridge/` (was `nvim-bridge.ts`), `lsp.ts`
- [x] nvim module (`nvim/lua/omp-lsp/`), wired in `nvim/plugin/ai.lua`
- [x] `lsp` tool + post-edit hook (edit/write/ast_edit) + refresh after bash/eval
- [x] E2E tests rust + ts (13 cases, stable over repeated runs)
- [x] Platform run (see below)
- [ ] Use it for real a while; then fold this file into AGENTS.md and delete it

## Platform run (`/tmp/omp-lsp-platform`, cold rust-analyzer)

- rust `references` in a file nvim never opened: 57 s (waited for the project load), all 3 hits,
  cross-crate included.
- rust edit introducing a type error: 1.5 s, rustc E0308 errors from the check the save triggered;
  reverting: 3.4 s, OK.
- ts `references` on a fresh buffer: first attempt returned only the definition (asked before
  tsserver started loading the project) → `fresh_ms`: navigation on a buffer omp just loaded waits
  ≥1 s and for progress to go quiet. Then 8 hits across 3 files, 5.8 s cold.
- ts edit: 1.2 s with the errors; nvim answered every 1 s probe in <100 ms throughout.

## Implementation notes

- Settled = no active `$/progress` *and* none in the last `quiet_ms`: loading a project is a chain
  of progress steps with idle gaps; without the second rule an edit right after startup returned
  "OK" from a half-loaded rust-analyzer.
- Requests answered `ContentModified`/`ServerCancelled` (LSP-standard "retry" codes) are retried.
- didSave goes through nvim's own `nvim.lsp.b_<buf>_save` BufWritePost group: what `:w` sends,
  without the user's write autocmds (formatters). Renames/code actions *do* `:write` the buffers
  they touch (formatters included), like doing it by hand; buffers with unsaved changes are left.

## Probe results (nvim 0.12.5, real config, rust-analyzer via rustaceanvim, ts_ls 5.3.0)

- Hidden `bufadd` + `swapfile=false` + `buflisted=false` + `bufload` attaches rust-analyzer and ts_ls
  through the normal FileType path. Copilot attaches to buffers too: ignore clients by capability.
- `:checktime` on an unmodified changed buffer → nvim sends `didClose` + `didOpen` (version 0), not
  `didChange`. nvim then pulls diagnostics itself where supported.
- rust-analyzer: advertises pull diagnostics (`diagnosticProvider`, no workspace pull). An explicit
  `textDocument/diagnostic` after the reload returns fresh *native* diagnostics (type mismatch etc.)
  deterministically. rustc/clippy diagnostics only come from flycheck, push-only, triggered by
  `didSave` (nvim does not send one on reload; sending it by hand works). Sequence:
  `progress rust-analyzer/flycheck/0 begin` → `publishDiagnostics v=0` → `progress … end`: a clean
  "done" signal. Startup also runs one flycheck after indexing (`cachePriming end`).
- rust-analyzer watches unopened files itself (nvim advertises `didChangeWatchedFiles`
  `dynamicRegistration = false`): an external change to an unopened `util.rs` showed up in the
  pull diagnostics of `main.rs` within ~2 s with no help.
- ts_ls: no pull diagnostics, push only, `version = nil` → no way to match a publish to a change.
  After reload: an empty publish right at `didClose`, the real one ~350 ms later; sometimes two
  publishes in a row. tsserver also noticed an external change to an unopened `a.ts` (~2.6 s) and
  republished for the open `b.ts`. `typescript-language-server` exposes
  `workspace/executeCommand typescript.tsserverRequest`: `semanticDiagnosticsSync {file}` through
  nvim's ts_ls client answered in 2 ms with the fresh error (tsserver format: 1-based
  `line`/`offset`, `text`, `code`, `category`). Deterministic, no waiting.

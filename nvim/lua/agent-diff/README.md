# agent-diff.nvim

See what Claude Code just changed, inline in your buffer, as it happens.

When the CLI agent edits a file, its changes light up right where they are: added
lines highlighted in place, removed lines shown as phantom lines above them. No
diff window, no context switch. Accept or reject stays where it belongs — in the
agent's own chat. This only shows you the change.

![added lines highlighted, deleted lines as virtual text]()

## How it works

Claude Code fires hooks around every tool call. A tiny shell hook forwards the
`Edit`/`Write`/`MultiEdit` events to the nvim hosting your [sidekick.nvim] session
over its RPC socket. The plugin diffs before-vs-after and paints extmarks.

- **Before the write** (`PreToolUse`) the proposed change previews with a gutter sign.
- **After the write lands** (`PostToolUse`) it re-renders as an applied diff and the
  edited file is brought on screen if the layout is unambiguous.
- Your **next keystroke** in the buffer clears the diff — it never lingers over text
  you're editing.

One edit is shown at a time. Every applied edit stays in a navigable history for the
session, so you can step back through what the agent did.

## Requirements

- Neovim 0.10+ (uses `vim.diff`, extmark `invalidate`, `vim.base64`).
- [sidekick.nvim] — the plugin hangs off its session and reads its highlight groups.
- Claude Code, running inside the nvim terminal (sidekick sets `$NVIM` for you).
- `base64` on `PATH`.

## Install

The Lua side is a normal plugin directory — point your plugin manager at it, or drop
it on the runtimepath, then:

```lua
require('agent-diff').setup()
```

The other half is a Claude Code hook. Register `agent-diff-hook.sh` for the three
events in your Claude `settings.json`:

```json
{
  "hooks": {
    "PreToolUse":  [{ "matcher": "Edit|Write|MultiEdit", "hooks": [{ "type": "command", "command": "~/path/to/agent-diff-hook.sh PreToolUse" }] }],
    "PostToolUse": [{ "matcher": "Edit|Write|MultiEdit", "hooks": [{ "type": "command", "command": "~/path/to/agent-diff-hook.sh PostToolUse" }] }],
    "Stop":        [{ "matcher": "",                      "hooks": [{ "type": "command", "command": "~/path/to/agent-diff-hook.sh Stop" }] }]
  }
}
```

The hook is a pure observer: it always exits 0 with no output, so it never blocks a
tool call or emits a permission decision. With no live nvim socket it's a no-op, so
it's safe to leave registered when you're not in nvim.

## Keymaps and commands

Nothing is bound by default. Wire up what you want:

```lua
vim.keymap.set('n', ']a', function() require('agent-diff').navigate(1) end)   -- next edit
vim.keymap.set('n', '[a', function() require('agent-diff').navigate(-1) end)  -- prev edit
vim.keymap.set('n', '<Esc>', function()                                       -- Esc hides the diff,
  if require('agent-diff').is_showing() then                                  -- else falls through
    require('agent-diff').clear()
  end
  return '<Esc>'
end, { expr = true })
```

| Command                        | Does                                        |
| ------------------------------ | ------------------------------------------- |
| `:AgentDiffClear`              | Hide the diff on screen                     |
| `:AgentDiffToggleAutoDisplay`  | Toggle pulling off-screen edits onto screen |
| `:AgentDiffReload`             | Hot-reload the plugin without restarting    |

Hiding never forgets an edit — `[a`/`]a` bring it back.

## Configuration

```lua
require('agent-diff').setup({
  queue = { max = 50 }, -- how many edits to keep navigable
  autodisplay = true,   -- pull an off-screen edited file onto screen when the
                        -- layout has exactly one editor window besides sidekick
  repo_only = true,     -- only track edits inside the editor's git worktree;
                        -- writes to scratchpads, /tmp, and other repos are
                        -- ignored — not previewed, rendered, or added to history
})
```

`autodisplay` can be flipped at runtime with `:AgentDiffToggleAutoDisplay` or
`require('agent-diff').toggle_autodisplay()` (pass a boolean to force a state). The
change takes effect from the next edit — nothing already on screen moves.

## Highlights

Linked to sidekick's groups when present, otherwise the stock `Diff*` groups, so it
matches your theme out of the box. Override any of `AgentDiffAdd`, `AgentDiffDelete`,
`AgentDiffPendingAdd`, `AgentDiffPendingDelete`, `AgentDiffSign` to taste.

## Development

```
just test              # full suite (headless, plenary)
just test-file <spec>  # one file
```

Contributor notes — architecture, invariants, the things that will bite — live in
[AGENTS.md](AGENTS.md).

[sidekick.nvim]: https://github.com/folke/sidekick.nvim

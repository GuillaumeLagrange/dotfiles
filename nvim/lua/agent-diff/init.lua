--- agent-diff.nvim — inline visualization of what a CLI coding agent changes,
--- hanging off the sidekick session. Visualize-only: accept/reject stays in the
--- agent's own chat. Public entry point: setup(), plus re-exported core ops.

local Core = require('agent-diff.core')
local Render = require('agent-diff.render')

local M = {}

--- Define our highlight groups. Prefer sidekick's groups (same visual language),
--- fall back to the stock Diff groups so we never depend on sidekick load order.
local function set_hl()
  local function link(name, ...)
    for _, target in ipairs({ ... }) do
      if vim.fn.hlexists(target) == 1 then
        vim.api.nvim_set_hl(0, name, { link = target, default = true })
        return
      end
    end
  end
  link('AgentDiffAdd', 'SidekickDiffAdd', 'DiffAdd')
  link('AgentDiffDelete', 'SidekickDiffDelete', 'DiffDelete')
  link('AgentDiffPendingAdd', 'SidekickDiffContext', 'DiffChange')
  link('AgentDiffPendingDelete', 'SidekickDiffDelete', 'DiffDelete')
  link('AgentDiffSign', 'SidekickSign', 'Special')
end

--- Clear a buffer's highlights the moment the user starts editing it, so stale
--- diffs never linger. `invalidate` on the extmarks only covers marks whose own
--- line is edited; this covers the rest.
local function attach_autoclear(buf)
  if vim.b[buf].agent_diff_autoclear then
    return
  end
  vim.b[buf].agent_diff_autoclear = true
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = buf,
    group = vim.api.nvim_create_augroup('agent_diff_autoclear_' .. buf, { clear = true }),
    callback = function()
      -- A `checktime` reload (how the agent's write reaches the buffer) also
      -- fires TextChanged but leaves the buffer unmodified; only a genuine user
      -- edit sets `modified`. Gate on it so we don't wipe a fresh diff.
      if vim.bo[buf].modified then
        Core.clear(buf)
      end
    end,
  })
end

--- Undo everything setup() created — diffs, autocmds, the user command, and the
--- per-buffer autoclear guard — so setup() can run again cleanly (see reload()).
function M.teardown()
  pcall(Core.clear)
  -- Every augroup we create is prefixed `agent_diff` (the static ones plus the
  -- per-buffer autoclear and per-path defer groups). Find them via their
  -- registered autocmds and delete each once.
  local seen = {}
  for _, au in ipairs(vim.api.nvim_get_autocmds({})) do
    local g = au.group_name
    if type(g) == 'string' and not seen[g] and g:find('^agent_diff') then
      seen[g] = true
      pcall(vim.api.nvim_del_augroup_by_name, g)
    end
  end
  pcall(vim.api.nvim_del_user_command, 'AgentDiffClear')
  pcall(vim.api.nvim_del_user_command, 'AgentDiffReload')
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.b[buf].agent_diff_autoclear = nil
    end
  end
end

--- Hot-reload the whole plugin in a running nvim: tear down, drop every
--- `agent-diff*` module from the cache, re-require, and re-run setup with the
--- opts last passed to setup(). Lets you see edits to the plugin without
--- restarting. Bound to a command/keymap in plugin/ai.lua.
function M.reload()
  local opts = M.config
  M.teardown()
  for name in pairs(package.loaded) do
    if name == 'agent-diff' or name:find('^agent%-diff%.') then
      package.loaded[name] = nil
    end
  end
  require('agent-diff').setup(opts)
  vim.notify('agent-diff: reloaded', vim.log.levels.INFO)
end

---@param opts? table
function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', Core.config, opts or {})
  Core.config = M.config

  set_hl()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('agent_diff_hl', { clear = true }),
    callback = set_hl,
  })

  -- Auto-clear on the user's next edit. Attach to every real buffer as it loads
  -- (and to those already loaded at setup time).
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile', 'BufWinEnter' }, {
    group = vim.api.nvim_create_augroup('agent_diff_attach', { clear = true }),
    callback = function(args)
      if vim.bo[args.buf].buftype == '' then
        attach_autoclear(args.buf)
      end
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' then
      attach_autoclear(buf)
    end
  end

  vim.api.nvim_create_user_command('AgentDiffClear', function()
    Core.clear()
  end, { desc = 'Clear agent inline diffs' })

  vim.api.nvim_create_user_command('AgentDiffReload', function()
    require('agent-diff').reload()
  end, { desc = 'Hot-reload the agent-diff plugin' })

  vim.api.nvim_create_user_command('AgentDiffToggleAutoDisplay', function()
    local on = Core.toggle_autodisplay()
    vim.notify('agent-diff: auto-display ' .. (on and 'on' or 'off'), vim.log.levels.INFO)
  end, { desc = 'Toggle agent-diff auto-display of off-screen edits' })
end

-- Re-export the operations callers (adapter, keymaps) need.
M.clear = Core.clear
M.navigate = Core.navigate
M.is_showing = Core.is_showing
M.toggle_autodisplay = Core.toggle_autodisplay
M.ns = Render.ns

return M

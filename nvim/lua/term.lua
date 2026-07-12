-- Terminal insert mode management
vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter' }, {
  pattern = 'term://*',
  callback = function()
    vim.cmd('startinsert')
  end,
})
vim.api.nvim_create_autocmd('BufLeave', {
  pattern = 'term://*',
  callback = function()
    -- Only stop insert mode when leaving for a non-terminal buffer
    vim.schedule(function()
      local buf = vim.api.nvim_get_current_buf()
      if vim.bo[buf].buftype ~= 'terminal' then
        vim.cmd('stopinsert')
      end
    end)
  end,
})

vim.keymap.set('t', '<C-h>', '<C-\\><C-n><C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('t', '<C-l>', '<C-\\><C-n><C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('t', '<C-j>', '<C-\\><C-n><C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('t', '<C-k>', '<C-\\><C-n><C-w><C-k>', { desc = 'Move focus to the upper window' })

-- Exit terminal mode in the builtin terminal
--vim.keymap.set('t', '<Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

-- Make Shift+Enter send the correct sequence in neovim terminal buffers (for Claude Code)
vim.keymap.set('t', '<S-Enter>', function()
  local chan = vim.b.terminal_job_id
  if chan then
    vim.api.nvim_chan_send(chan, '\x1b[13;2u')
  end
end, { desc = 'Send Shift+Enter to terminal' })

-- Exit terminal mode with `jk` so Esc stays free for the CLI agent (Claude uses
-- it to interrupt/clear). Only fires when both keys land within 'timeoutlen';
-- type them slower and they pass through to the terminal.
--
-- A terminal running a nested full-screen app that binds `jk` itself (another
-- (n)vim, lazygit) needs those keys for its own use, and an expr mapping is not
-- enough: `j` alone would still stall for 'timeoutlen' waiting on a possible
-- `k`. So the mapping is fully removed from the buffer while such an app is
-- running and restored once it exits. A short poll of the terminal's process
-- tree, active only while the buffer is in terminal mode, drives the transition.
local jk_stealing_apps = {
  nvim = true,
  vim = true,
  lazygit = true,
}

local function terminal_hosts_jk_app(shell_pid)
  local function children(pid)
    local f = io.open(string.format('/proc/%d/task/%d/children', pid, pid), 'r')
    if not f then
      return {}
    end
    local line = f:read('*a') or ''
    f:close()
    local kids = {}
    for p in line:gmatch('%d+') do
      kids[#kids + 1] = tonumber(p)
    end
    return kids
  end

  local function comm(pid)
    local f = io.open(string.format('/proc/%d/comm', pid), 'r')
    if not f then
      return nil
    end
    local c = f:read('*l')
    f:close()
    return c
  end

  local function walk(pid, depth)
    if depth > 20 then
      return false
    end
    for _, kid in ipairs(children(pid)) do
      local c = comm(kid)
      if c and jk_stealing_apps[c] then
        return true
      end
      if walk(kid, depth + 1) then
        return true
      end
    end
    return false
  end

  return walk(shell_pid, 0)
end

local function set_jk_mapping(buf)
  vim.keymap.set('t', 'jk', '<C-\\><C-n>', {
    buffer = buf,
    desc = 'Exit terminal to normal mode',
  })
end

local function sync_jk_mapping(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local shell_pid = vim.b[buf].terminal_job_pid
  if not shell_pid then
    return
  end
  local mapped = vim.b[buf].jk_terminal_mapped
  if terminal_hosts_jk_app(shell_pid) then
    if mapped then
      pcall(vim.keymap.del, 't', 'jk', { buffer = buf })
      vim.b[buf].jk_terminal_mapped = false
    end
  elseif not mapped then
    set_jk_mapping(buf)
    vim.b[buf].jk_terminal_mapped = true
  end
end

-- Poll timers keyed by buffer, so start/stop is idempotent regardless of which
-- event (TermLeave, TermClose, BufWipeout) tears the terminal down first.
local jk_timers = {}

local function stop_poll(buf)
  local timer = jk_timers[buf]
  if not timer then
    return
  end
  jk_timers[buf] = nil
  timer:stop()
  if not timer:is_closing() then
    timer:close()
  end
end

local function start_poll(buf)
  if jk_timers[buf] then
    return
  end
  local timer = vim.uv.new_timer()
  jk_timers[buf] = timer
  timer:start(
    0,
    200,
    vim.schedule_wrap(function()
      if not vim.api.nvim_buf_is_valid(buf) then
        stop_poll(buf)
        return
      end
      sync_jk_mapping(buf)
    end)
  )
end

local jk_group = vim.api.nvim_create_augroup('terminal-jk-exit', { clear = true })

vim.api.nvim_create_autocmd('TermOpen', {
  group = jk_group,
  callback = function(ev)
    set_jk_mapping(ev.buf)
    vim.b[ev.buf].jk_terminal_mapped = true
  end,
})

vim.api.nvim_create_autocmd('TermEnter', {
  group = jk_group,
  callback = function(ev)
    start_poll(ev.buf)
  end,
})

vim.api.nvim_create_autocmd({ 'TermLeave', 'TermClose', 'BufWipeout' }, {
  group = jk_group,
  callback = function(ev)
    stop_poll(ev.buf)
  end,
})

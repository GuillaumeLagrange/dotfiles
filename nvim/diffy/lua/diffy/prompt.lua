-- Small, reusable key-driven confirmation float (contract §11.2: nvim is
-- never mocked in tests, so a modal `vim.fn.confirm` - which doesn't even
-- block for real input in the test harness, see AGENTS.md - can't be the
-- only way diffy asks "are you sure?"). Any confirmation in the plugin
-- (conflict.lua's `s` with markers left today; §9.4 pull's "asks before
-- replacing" is the next expected caller) should go through this instead.
local session_mod = require('diffy.session')

local M = {}

--- Opens a small centered float showing `lines` and waits for one real
--- keypress: `y`/`<CR>` accepts, `n`/`<Esc>`/`q` declines. Calls
--- `cb(accepted)` exactly once, then closes the float and drops its
--- buffer-local keymaps - nothing outlives the answer.
--- @param session table  owning diffy session (buffer/keymap tracking, so
---   the leak check's `diffy://`/`diffy: ` conventions cover this too)
--- @param lines string[]  message lines shown in the float
--- @param cb fun(accepted: boolean)
function M.confirm(session, lines, cb)
  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, #l + 2)
  end
  width = math.min(width, vim.o.columns - 4)
  local height = #lines

  local buf = session_mod.scratch_buf(session, 'prompt')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  session_mod.register_buffer(session, 'prompt', buf)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    zindex = 200,
  })

  local done = false
  local function finish(accepted)
    if done then
      return
    end
    done = true
    session_mod.unmap_buffer(session, buf)
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    cb(accepted)
  end

  local function key(lhs, accepted)
    session_mod.map(session, 'n', lhs, function()
      finish(accepted)
    end, { buffer = buf, desc = 'confirm: ' .. lhs })
  end
  key('y', true)
  key('<CR>', true)
  key('n', false)
  key('<Esc>', false)
  key('q', false)
end

return M

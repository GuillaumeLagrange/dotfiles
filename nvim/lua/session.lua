local M = {}
local H = {}

M.session_file = 'Session.vim'

M.delete_all = function()
  -- Delete all sessions in MiniSessions.detected
  for _, session in pairs(MiniSessions.detected) do
    if string.find(vim.v.this_session, session.name) == nil then
      MiniSessions.delete(session.name)
    end
  end
end

M.close_ephemeral_buffers = function()
  local patterns = { 'fugitive://.*', 'term://.*', 'octo://.*', 'OctoChangedFile.*', 'diffview://.*' }

  -- close all buffers when the name matches any of the pattern
  for _, pattern in ipairs(patterns) do
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      if vim.fn.bufname(buffer):match(pattern) then
        vim.api.nvim_buf_delete(buffer, { force = true })
      end
    end
  end
end

-- Taken from mini.sessions, because vim.fn.argc fails on NixOS
H.is_something_shown = function()
  -- Don't autoread session if Neovim is opened to show something. That is
  -- when at least one of the following is true:
  -- - There are files in arguments (like `nvim foo.txt` with new file).
  if vim.fn.argc() > 0 then
    return true
  end

  -- - Several buffers are listed (like session with placeholder buffers). That
  --   means unlisted buffers (like from `nvim-tree`) don't affect decision.
  local listed_buffers = vim.tbl_filter(function(buf_id)
    return vim.fn.buflisted(buf_id) == 1
  end, vim.api.nvim_list_bufs())
  if #listed_buffers > 1 then
    return true
  end

  -- - Current buffer is meant to show something else
  if vim.bo.filetype ~= '' then
    return true
  end

  -- - Current buffer has any lines (something opened explicitly).
  -- NOTE: Usage of `line2byte(line('$') + 1) < 0` seemed to be fine, but it
  -- doesn't work if some automated changed was made to buffer while leaving it
  -- empty (returns 2 instead of -1). This was also the reason of not being
  -- able to test with child Neovim process from 'tests/helpers'.
  local n_lines = vim.api.nvim_buf_line_count(0)
  if n_lines > 1 then
    return true
  end
  local first_line = vim.api.nvim_buf_get_lines(0, 0, 1, true)[1]
  if string.len(first_line) > 0 then
    return true
  end

  return false
end

M.ensure_session = function()
  -- Avoid creating a session file when called with an argument
  if H.is_something_shown() then
    return
  end

  local f = io.open(M.session_file, 'r')
  if f == nil then
    vim.cmd('silent! mksession ' .. M.session_file)
  else
    f:close()
  end
end

return M

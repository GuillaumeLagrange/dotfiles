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
  local patterns = { 'fugitive://.*', 'term://.*', 'diffy://.*' }

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

-- A `.git` dir, or the `.git` file of a worktree or submodule
H.is_git_root = function()
  return vim.uv.fs_stat(vim.fn.getcwd() .. '/.git') ~= nil
end

-- Reads the local session, or starts one, only at the root of a git checkout
M.ensure_session = function()
  if H.is_something_shown() or not H.is_git_root() then
    return
  end

  if vim.uv.fs_stat(M.session_file) then
    MiniSessions.read(M.session_file)
  else
    MiniSessions.write(M.session_file)
  end
end

return M

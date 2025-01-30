local M = {}

-- local function get_session_name()
--   local name = string.gsub(vim.fn.getcwd(), '/', '_')
--   -- local branch = vim.trim(vim.fn.system('git branch --show-current'))
--   -- if vim.v.shell_error == 0 and branch ~= '' then
--   --   return name .. '_' .. branch
--   -- else
--   return name
--   -- end
-- end

-- if vim.fn.argc(-1) == 0 then
--   vim.api.nvim_create_autocmd({ 'VimEnter' }, {
--     nested = true,
--     callback = function()
--       local session_name = get_session_name()
--
--       if MiniSessions.detected[session_name] and string.find(vim.v.this_session, session_name, 1, true) == nil then
--         MiniSessions.read(session_name)
--       else
--         -- If we are opening a new branch, create a session for the new branch with current state
--         MiniSessions.write(get_session_name())
--       end
--     end,
--   })
--
--   vim.api.nvim_create_autocmd('VimLeavePre', {
--     callback = function()
--       if vim.v.this_session == '' then
--         return
--       end
--
--       MiniSessions.write(get_session_name())
--     end,
--   })
-- end

M.delete_all = function()
  -- Delete all sessions in MiniSessions.detected
  for _, session in pairs(MiniSessions.detected) do
    if string.find(vim.v.this_session, session.name) == nil then
      MiniSessions.delete(session.name)
    end
  end
end

M.close_ephemeral_buffers = function()
  -- define a table with patterns
  local patterns = { 'fugitive://.*', 'term://.*', 'octo://.*', 'OctoChangedFile.*', 'diffview://.*' }

  -- close all buffers when the name matches any of the patter
  for _, pattern in ipairs(patterns) do
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      if vim.fn.bufname(buffer):match(pattern) then
        vim.api.nvim_buf_delete(buffer, { force = true })
      end
    end
  end
end

return M

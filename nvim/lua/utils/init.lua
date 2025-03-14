local log = require('utils.log')

local M = {}

local is_underline_enabled = true
vim.diagnostic.config({ underline = is_underline_enabled })
M.toggle_diagnostic_underline = function()
  is_underline_enabled = not is_underline_enabled
  vim.diagnostic.config({ underline = is_underline_enabled })
end

M.toggle_inlay_hints = function(bufnr)
  vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled({ bufnr }), { bufnr })
end

M.toggle_relative_number = function()
  ---@diagnostic disable-next-line: undefined-field
  if vim.opt_local.relativenumber:get() then
    vim.opt_local.relativenumber = false
    log.info('Enabled relativenumber', { title = 'Diagnostics' })
  else
    vim.opt_local.relativenumber = true
    log.info('Disabled relativenumber', { title = 'Diagnostics' })
  end
end

M.toggle_diagnostics = function()
  vim.diagnostic.enable(not vim.diagnostic.is_enabled())
end

M.get_git_main_branch = function()
  -- Get the directory of the current buffer
  local buffer_dir = vim.fn.expand('%:p:h')

  -- Get the list of local branches
  -- local git_cmd = 'git -C ' .. vim.fn.shellescape(buffer_dir) .. ' branch --list --format=%(refname:short) 2>/dev/null'
  local git_cmd = 'git -C ' .. vim.fn.shellescape(buffer_dir) .. " branch --list --format='%(refname:short)'"
  local branches = vim.fn.system(git_cmd)

  -- Check if the command succeeded
  if vim.v.shell_error ~= 0 then
    return nil
  end

  for branch in branches:gmatch('[^\r\n]+') do
    if branch == 'main' or branch == 'master' then
      return branch
    end
  end
end

M.get_git_root = function()
  local dot_git_path = vim.fn.finddir('.git', '.;')
  if dot_git_path == '' then
    return vim.fn.expand('~')
  end
  return vim.fn.fnamemodify(dot_git_path, ':h')
end

M.close_octo_buffers = function()
  local buffers = vim.api.nvim_list_bufs()
  for _, buf in ipairs(buffers) do
    local buf_name = vim.api.nvim_buf_get_name(buf)

    if buf_name:match('^octo://') and vim.api.nvim_get_option_value('modified', { buf = buf }) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
end

M.toggle_option = function(option_name)
  local buf = vim.api.nvim_get_current_buf()
  local value = vim.api.nvim_buf_get_option(buf, option_name)
  vim.api.nvim_buf_set_option(buf, option_name, not value)
end

M.close_windowless_buffers = function()
  local all_buffers = vim.api.nvim_list_bufs()
  local visible_buffers = {}

  -- Collect all buffers currently displayed in visible windows
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)

    visible_buffers[buf] = true
  end

  -- Iterate through all buffers and delete the hidden ones
  for _, buf in ipairs(all_buffers) do
    if not visible_buffers[buf] then
      if not vim.api.nvim_buf_get_option(buf, 'modified') then
        vim.api.nvim_buf_delete(buf, { force = true })
      else
        local choice = vim.fn.confirm(('Save changes to %q?'):format(vim.fn.bufname()), '&Yes\n&No\n&Cancel')
        if choice == 1 then -- Yes
          vim.api.nvim_buf_call(buf, function()
            vim.cmd('write')
          end)
          vim.api.nvim_buf_delete(buf, { force = true })
        elseif choice == 2 then -- No
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
    end
  end
end

-- Treesitter foldexpr can be very slow, this wrapper
M.foldexpr = function()
  local buf = vim.api.nvim_get_current_buf()
  if vim.b[buf].ts_folds == nil then
    if vim.bo[buf].filetype == '' then
      return '0'
    end
    if vim.bo[buf].filetype:find('dashboard') then
      vim.b[buf].ts_folds = false
    else
      vim.b[buf].ts_folds = pcall(vim.treesitter.get_parser, buf)
    end
  end
  return vim.b[buf].ts_folds and vim.treesitter.foldexpr() or '0'
end

return M

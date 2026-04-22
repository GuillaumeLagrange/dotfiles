local M = {}

M.threshold = 1024 * 1024 -- 1 MB

local function is_large(path)
  local ok, stats = pcall(vim.uv.fs_stat, path)
  return ok and stats and stats.size and stats.size > M.threshold
end

local function on_large_buffer(buf)
  -- Shadow matchit's global `%` with the builtin `%`
  local opts = { buffer = buf, silent = true, remap = false }
  for _, mode in ipairs({ 'n', 'x', 'o' }) do
    vim.keymap.set(mode, '%', '%', opts)
    vim.keymap.set(mode, 'g%', '%', opts)
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.wo[win].breakindent = false
  end
end

function M.setup()
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
    group = vim.api.nvim_create_augroup('large_files', { clear = true }),
    callback = function(ev)
      if is_large(ev.file) then
        on_large_buffer(ev.buf)
      end
    end,
  })
end

return M

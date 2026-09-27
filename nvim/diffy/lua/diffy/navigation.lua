-- BufWinEnter-driven pair swapping in the right diff window when it shows a
-- real file: a jump to another file already in the current
-- list (go-to-definition, `gf`, `:e`) swaps both sides and highlights it in
-- the tree; a jump outside the list leaves diff mode with a placeholder.
local M = {}

--- `buf`'s path relative to `session.root`, or `nil` if it isn't under it
--- (a scratch buffer, another repo entirely, or an unnamed buffer).
local function relative_path(session, buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then
    return nil
  end
  local abs = vim.fn.fnamemodify(name, ':p')
  local root = vim.fn.fnamemodify(session.root, ':p')
  if abs:sub(1, #root) ~= root then
    return nil
  end
  return abs:sub(#root + 1)
end

local function find_row(session, path)
  for _, row in ipairs(session.tree_rows or {}) do
    if row.kind == 'file' and row.entry.path == path then
      return row
    end
  end
  return nil
end

--- React to the right window's buffer becoming `buf`: swap in the matching
--- pair if its path is in the current file list, otherwise leave diff mode
--- with an "outside diff" placeholder.
local function handle(session, buf)
  local path = relative_path(session, buf)
  if path and find_row(session, path) then
    require('diffy.panels.tree').open_path(session, path)
  else
    require('diffy.diffpair').leave(session)
  end
end

--- Arm the `BufWinEnter` autocmd on the session augroup, scoped to the right
--- diff window. Ignores buffer changes made by diffy itself (`_nav_guard`).
function M.setup(session)
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = session.augroup,
    callback = function(args)
      if (session._nav_guard or 0) > 0 then
        return
      end
      local right = session.wins.right
      if not (right and vim.api.nvim_win_is_valid(right)) or vim.api.nvim_get_current_win() ~= right then
        return
      end
      handle(session, args.buf)
    end,
  })
end

return M

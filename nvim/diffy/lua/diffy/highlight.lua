-- Panel highlight groups (contract §2). All `default = true`, so a
-- colorscheme or the user can override any of them.
local M = {}

local LINKS = {
  DiffyAdded = 'Added',
  DiffyChanged = 'Changed',
  DiffyRemoved = 'Removed',
  DiffyConflict = 'DiagnosticError',
  DiffyDirectory = 'Directory',
  DiffySha = 'Identifier',
  DiffyMerge = 'Comment',
  DiffyLabel = 'Title',
  DiffySelection = 'Visual',
  -- not CursorLine: the panel's own cursorline would make it invisible
  DiffyCurrentFile = 'Visual',
  DiffyThreadSummary = 'Special',
}

--- Status letter -> highlight group.
M.STATUS = {
  A = 'DiffyAdded',
  ['?'] = 'DiffyAdded',
  M = 'DiffyChanged',
  R = 'DiffyChanged',
  C = 'DiffyChanged',
  D = 'DiffyRemoved',
  U = 'DiffyConflict',
}

function M.setup()
  for name, target in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  vim.api.nvim_set_hl(0, 'DiffyCurrentFileName', { bold = true, default = true })
end

--- Truncate `s` to at most `width` display cells, ending in '…' if cut.
function M.truncate(s, width)
  if vim.fn.strdisplaywidth(s) <= width then
    return s
  end
  if width <= 0 then
    return ''
  end
  local out, w = {}, 0
  for _, ch in ipairs(vim.fn.split(s, '\\zs')) do
    local cw = vim.fn.strdisplaywidth(ch)
    if w + cw > width - 1 then
      break
    end
    table.insert(out, ch)
    w = w + cw
  end
  return table.concat(out) .. '…'
end

--- Like `truncate`, but keeps the end of `s` ('…' first): for paths,
--- whose file name is the part worth seeing.
function M.truncate_left(s, width)
  if vim.fn.strdisplaywidth(s) <= width then
    return s
  end
  if width <= 0 then
    return ''
  end
  local chars = vim.fn.split(s, '\\zs')
  local out, w = {}, 0
  for i = #chars, 1, -1 do
    local cw = vim.fn.strdisplaywidth(chars[i])
    if w + cw > width - 1 then
      break
    end
    table.insert(out, 1, chars[i])
    w = w + cw
  end
  return '…' .. table.concat(out)
end

--- Usable text width of `win` (window width minus number/sign columns).
function M.text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  return info.width - info.textoff
end

return M

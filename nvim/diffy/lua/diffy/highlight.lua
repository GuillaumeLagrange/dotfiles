-- Panel highlight groups. All `default = true`, so a colorscheme or the
-- user can override any of them.
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
  DiffyThreadSummary = 'Comment',
  DiffyThreadSummaryResolved = 'NonText',
  DiffyThreadRelevant = 'Special',
  DiffyThreadCurrent = 'PmenuSel',
  -- drawn on the number column, so it needs a strong background
  DiffyThreadRange = 'PmenuSel',
  DiffyThreadTime = 'Comment',
  DiffyThreadKey = 'Special',
  DiffyThreadHint = 'Comment',
  DiffyThreadDraft = 'DiagnosticWarn',
  DiffyThreadPending = 'DiagnosticInfo',
  DiffyThreadSent = 'Comment',
  DiffyThreadResolved = 'DiagnosticOk',
  DiffyThreadOutdated = 'DiagnosticWarn',
  DiffyThreadCodeBar = 'Comment',
  DiffyThreadSuggestion = 'Added',
  DiffyThreadAuthor1 = 'Identifier',
  DiffyThreadAuthor2 = 'DiagnosticHint',
  DiffyThreadAuthor3 = 'Constant',
  DiffyThreadAuthor4 = 'Title',
  DiffyThreadAuthor5 = 'Function',
}

-- author name colours, picked by login
M.AUTHOR_COLORS = 5

--- The colour group of an author's name, the same one everywhere.
function M.author(name)
  local sum = 0
  for i = 1, #name do
    sum = sum + name:byte(i)
  end
  return 'DiffyThreadAuthor' .. (sum % M.AUTHOR_COLORS + 1)
end

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

--- First `key` ('fg'/'bg') colour among `groups`.
local function color_of(key, ...)
  for _, g in ipairs({ ... }) do
    local h = vim.api.nvim_get_hl(0, { name = g, link = false })
    if h[key] then
      return h[key]
    end
  end
end

function M.setup()
  for name, target in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  vim.api.nvim_set_hl(0, 'DiffyCurrentFileName', { bold = true, default = true })
  -- background only: Normal/NormalFloat are often transparent, and linking
  -- to CursorLine or Pmenu would drag in their underline/foreground
  local card = color_of('bg', 'CursorLine', 'StatusLine', 'Pmenu')
  vim.api.nvim_set_hl(0, 'DiffyThread', { bg = card, default = true })
  vim.api.nvim_set_hl(0, 'DiffyThreadHeader', { bg = color_of('bg', 'Pmenu', 'Visual', 'StatusLine'), default = true })
  -- a separator-coloured line on the card's own background, so the frame
  -- belongs to the card and titles/footers sit on it without patches
  vim.api.nvim_set_hl(0, 'DiffyThreadBorder', { fg = color_of('fg', 'WinSeparator', 'FloatBorder', 'Comment'), bg = card, default = true })
  vim.api.nvim_set_hl(0, 'DiffyThreadAuthor', { bold = true, default = true })
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

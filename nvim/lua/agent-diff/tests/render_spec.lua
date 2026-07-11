local Render = require('agent-diff.render')
local Diff = require('agent-diff.diff')

--- Place a diff's marks in a fresh buffer holding `new` and return the extmarks
--- (with details) sorted by start row.
local function marks_for(old, new)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, new)
  Render.hunks(buf, Diff.hunks(old, new), 'applied')
  local marks = vim.api.nvim_buf_get_extmarks(buf, Render.ns, 0, -1, { details = true })
  table.sort(marks, function(a, b)
    return a[2] < b[2]
  end)
  return marks, buf
end

describe('render.hunks', function()
  it('add highlight ends within the added block, not on the next line', function()
    -- Two lines inserted between 'e' and 'f'. The add hunk covers rows 5-6; its
    -- highlight must not extend onto row 7 ('f'), or an unchanged line lights up.
    local old = { 'a', 'b', 'c', 'd', 'e', 'f' }
    local new = { 'a', 'b', 'c', 'd', 'e', 'NEW1', 'NEW2', 'f' }
    local marks = marks_for(old, new)

    local add = marks[1]
    assert.equals(5, add[2]) -- starts on the first added row
    -- Ends on the last added row (6, 'NEW2'), at its end-of-line — never row 7.
    assert.equals(6, add[4].end_row)
    assert.is_true(add[4].end_row < 7)
  end)

  it('single added line at end of file stays on that line', function()
    local marks, buf = marks_for({ 'a', 'b' }, { 'a', 'b', 'TAIL' })
    local add = marks[1]
    assert.equals(2, add[2])
    assert.equals(2, add[4].end_row)
    assert.equals(#'TAIL', add[4].end_col)
    assert.equals(vim.api.nvim_buf_line_count(buf) - 1, add[4].end_row)
  end)
end)

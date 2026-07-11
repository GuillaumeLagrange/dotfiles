local Diff = require('agent-diff.diff')

--- Compact a hunk to {kind, b_start, b_count, a_lines} for readable assertions.
local function h(hunk)
  return { hunk.kind, hunk.b_start, hunk.b_count, hunk.a_lines }
end

describe('diff.hunks', function()
  it('single-line change', function()
    local hunks = Diff.hunks({ 'a', 'hello', 'c' }, { 'a', 'HELLO', 'c' })
    assert.same({ { 'change', 1, 1, { 'hello' } } }, vim.tbl_map(h, hunks))
  end)

  it('partial-line change keeps the whole line as the unit', function()
    local hunks = Diff.hunks({ 'foo bar baz' }, { 'foo BAR baz' })
    assert.same({ { 'change', 0, 1, { 'foo bar baz' } } }, vim.tbl_map(h, hunks))
  end)

  it('multi-line insertion inside a change', function()
    local hunks = Diff.hunks({ 'top', 'old', 'bottom' }, { 'top', 'X1', 'X2', 'X3', 'bottom' })
    assert.equals(2, #hunks)
    local added, deleted = 0, {}
    for _, hk in ipairs(hunks) do
      added = added + hk.b_count
      vim.list_extend(deleted, hk.a_lines)
    end
    assert.equals(3, added)
    assert.same({ 'old' }, deleted)
  end)

  it('pure delete, middle', function()
    local hunks = Diff.hunks({ 'a', 'b', 'c' }, { 'a', 'c' })
    assert.same({ { 'delete', 1, 0, { 'b' } } }, vim.tbl_map(h, hunks))
  end)

  it('pure delete, first line anchors above the surviving line', function()
    local hunks = Diff.hunks({ 'a', 'b', 'c' }, { 'b', 'c' })
    assert.same({ { 'delete', 0, 0, { 'a' } } }, vim.tbl_map(h, hunks))
  end)

  it('pure delete, last line anchors at end of file', function()
    local hunks = Diff.hunks({ 'a', 'b', 'c' }, { 'a', 'b' })
    -- b_start == line count marks an end-of-file deletion
    assert.same({ { 'delete', 2, 0, { 'c' } } }, vim.tbl_map(h, hunks))
  end)

  it('pure insertion at beginning of file', function()
    local hunks = Diff.hunks({ 'a', 'b' }, { 'NEW', 'a', 'b' })
    assert.same({ { 'add', 0, 1, {} } }, vim.tbl_map(h, hunks))
  end)

  it('pure insertion at end of file', function()
    local hunks = Diff.hunks({ 'a', 'b' }, { 'a', 'b', 'NEW' })
    assert.same({ { 'add', 2, 1, {} } }, vim.tbl_map(h, hunks))
  end)

  it('nil old_file renders as one all-added hunk', function()
    assert.same({ { 'add', 0, 3, {} } }, vim.tbl_map(h, Diff.hunks(nil, { 'x', 'y', 'z' })))
  end)

  it('nil old_file with empty new_file yields no hunks', function()
    assert.same({}, Diff.hunks(nil, {}))
  end)

  it('identical files yield no hunks', function()
    assert.same({}, Diff.hunks({ 'a', 'b' }, { 'a', 'b' }))
  end)

  it('whole-file replace produces both add and delete hunks', function()
    local adds, dels = 0, 0
    for _, hk in ipairs(Diff.hunks({ 'a', 'b', 'c' }, { 'x', 'y' })) do
      adds = adds + (hk.b_count > 0 and 1 or 0)
      dels = dels + (#hk.a_lines > 0 and 1 or 0)
    end
    assert.is_true(adds > 0)
    assert.is_true(dels > 0)
  end)
end)

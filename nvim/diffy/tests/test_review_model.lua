-- Pure review/model.lua logic with edges a UI scenario can't hit
-- deterministically: excerpt relocation's +/-20 line search window, and the
-- code snippet shown with a thread (hunk parsing, cutting long ranges).
--
-- Everything else review/model.lua's local backend does (relocate finding
-- a shifted/deleted excerpt, pair_side placement, id generation,
-- summary_text, find_hunk's diff-hunk lookup) is proven by the UI
-- scenarios in tests/test_review_local.lua that exercise it through real
-- keys and files.
local model = require('diffy.review.model')

local T = MiniTest.new_set()

T['relocate gives up beyond the +/-20 line window'] = function()
  local lines = {}
  for i = 1, 60 do
    lines[i] = 'line ' .. i
  end
  lines[45] = 'target'
  local anchor = { start_line = 10, end_line = 10, excerpt = { 'target' } }
  MiniTest.expect.equality(model.relocate(anchor, lines), false)
end

local function hunk_thread(side, start_line, end_line, hunk)
  return {
    anchor = { side = side, start_line = start_line, end_line = end_line },
    _raw_comments = { { diffHunk = hunk } },
  }
end

T["a GitHub thread's code is its hunk's last lines on its side, with three lines of context"] = function()
  -- a new-side comment on lines 12-13; GitHub's hunk ends on line 13
  local rows = model.snippet(hunk_thread('new', 12, 13, table.concat({
    '@@ -8,6 +8,7 @@ local function f()',
    ' eight',
    ' nine',
    ' ten',
    '-old eleven',
    '+new eleven',
    '+twelve',
    '+thirteen',
  }, '\n')), 20)
  local shown = vim.tbl_map(function(r)
    return { r.n, r.text, r.kind or 'ctx', r.range }
  end, rows)
  MiniTest.expect.equality(shown, {
    { 10, 'ten', 'ctx', false },
    { 11, 'old eleven', 'del', false },
    { 11, 'new eleven', 'add', false },
    { 12, 'twelve', 'add', true },
    { 13, 'thirteen', 'add', true },
  })
end

T['a long commented range keeps its start and more of its end, the middle cut'] = function()
  local excerpt = {}
  for i = 1, 200 do
    excerpt[i] = 'line ' .. i
  end
  local rows = model.snippet({ anchor = { side = 'new', start_line = 1, end_line = 200, excerpt = excerpt } }, 14)
  MiniTest.expect.equality(#rows, 14)
  MiniTest.expect.equality({ rows[1].n, rows[4].n, rows[5].gap, rows[6].n, rows[14].n }, { 1, 4, 187, 192, 200 })
end

return T

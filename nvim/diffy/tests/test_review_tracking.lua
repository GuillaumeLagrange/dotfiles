-- §9.4, §12.7 (phase 7, logic): GitHub backend line tracking, anchor
-- validity and `position` computation. Pure `review/model.lua` functions;
-- inputs are real `git diff` output from fixture repos (§11.2), never
-- hand-built diff shapes for the tracking/position tests (the anchor
-- validity one hand-builds a diff hunk, same style as
-- `test_review_model.lua`'s `find_hunk` case).
local Repo = require('tests.helpers.repo')
local model = require('diffy.review.model')

local T = MiniTest.new_set()

local function git_diff(dir, a, b, extra)
  local args = { 'diff', '-M' }
  vim.list_extend(args, extra or { '-U0' })
  table.insert(args, a)
  table.insert(args, b)
  local res = vim.system({ 'git', unpack(args) }, { cwd = dir, text = true }):wait()
  assert(res.code == 0, res.stderr)
  return res.stdout
end

T['§9.4: map_line/map_range track an unrenamed line across an edit, in both directions'] = function()
  local r = Repo.new()
  r:commit('Base', { ['f.txt'] = Repo.lines(60) })
  r:commit('Edit', { ['f.txt'] = Repo.edit(11, 'line 11 EDIT', 50, 'line 50 EDIT') })

  local files = model.parse_diff_files(git_diff(r.dir, r.sha.Base, r.sha.Edit))
  local _, hunks = model.diff_file_hunks(files, 'f.txt')
  -- line 5 (before every hunk) and line 30 (between the two hunks) are
  -- unaffected; line 11 and 50 are exactly the changed lines
  MiniTest.expect.equality(model.map_line(hunks, 5), 5)
  MiniTest.expect.equality(model.map_line(hunks, 30), 30)
  MiniTest.expect.equality(model.map_line(hunks, 11), nil)
  MiniTest.expect.equality(model.map_line(hunks, 50), nil)
  -- a range whose endpoints survive but whose interior changed still maps
  -- (contract §9.4: "lines inside the range may have changed")
  local s, e = model.map_range(hunks, 10, 12)
  MiniTest.expect.equality(s, 10)
  MiniTest.expect.equality(e, 12)

  -- the other direction of history: same pair, diffed the other way round
  local back_files = model.parse_diff_files(git_diff(r.dir, r.sha.Edit, r.sha.Base))
  local _, back_hunks = model.diff_file_hunks(back_files, 'f.txt')
  MiniTest.expect.equality(model.map_line(back_hunks, 5), 5)
  MiniTest.expect.equality(model.map_line(back_hunks, 11), nil)

  r:destroy()
end

T['§9.4: map_line tracks a renamed file (rename-aware git diff -M), in both directions'] = function()
  local r = Repo.new()
  r:commit('Base', { ['old.txt'] = Repo.lines(20, 'r') })
  r:branch('feat'):mv('old.txt', 'new.txt'):commit('Rename', { ['new.txt'] = Repo.edit(10, 'r10 EDITED') })

  local files = model.parse_diff_files(git_diff(r.dir, r.sha.Base, r.sha.Rename))
  local new_path, hunks = model.diff_file_hunks(files, 'old.txt')
  MiniTest.expect.equality(new_path, 'new.txt')
  MiniTest.expect.equality(model.map_line(hunks, 5), 5) -- unaffected, survives the rename
  MiniTest.expect.equality(model.map_line(hunks, 10), nil) -- the edited line

  -- backward: from the renamed file's own name back to the old one
  local back_files = model.parse_diff_files(git_diff(r.dir, r.sha.Rename, r.sha.Base))
  local old_path, back_hunks = model.diff_file_hunks(back_files, 'new.txt')
  MiniTest.expect.equality(old_path, 'old.txt')
  MiniTest.expect.equality(model.map_line(back_hunks, 15), 15)
  MiniTest.expect.equality(model.map_line(back_hunks, 10), nil)

  r:destroy()
end

T['§9.4: map_line handles a pure line insertion (zero-count hunk) without shifting the anchor line itself'] = function()
  local r = Repo.new()
  r:commit('Base', { ['f.txt'] = Repo.lines(20) })
  r:commit('Insert', {
    ['f.txt'] = function(lines)
      local out = vim.deepcopy(lines)
      table.insert(out, 12, 'inserted a')
      table.insert(out, 13, 'inserted b')
      table.insert(out, 14, 'inserted c')
      return out
    end,
  })

  local files = model.parse_diff_files(git_diff(r.dir, r.sha.Base, r.sha.Insert))
  local _, hunks = model.diff_file_hunks(files, 'f.txt')
  -- old line 11 (right before the insertion point) is unaffected...
  MiniTest.expect.equality(model.map_line(hunks, 11), 11)
  -- ...while old line 12 (the first line pushed down) shifts by 3
  MiniTest.expect.equality(model.map_line(hunks, 12), 15)

  r:destroy()
end

T['§9.4: anchor_valid accepts a changed line and up to 3 lines of context, rejects beyond that'] = function()
  local diff = table.concat({
    '@@ -20,3 +20,3 @@',
    '-old a',
    '-old b',
    '-old c',
    '+new a',
    '+new b',
    '+new c',
  }, '\n')
  local hunks = model.parse_hunks(diff)
  -- changed range itself
  MiniTest.expect.equality(model.anchor_valid(hunks, 'new', 20, 22), true)
  -- exactly 3 lines above/below (17..19 and 23..25)
  MiniTest.expect.equality(model.anchor_valid(hunks, 'new', 17, 17), true)
  MiniTest.expect.equality(model.anchor_valid(hunks, 'new', 25, 25), true)
  -- one line beyond the ±3 window on either side
  MiniTest.expect.equality(model.anchor_valid(hunks, 'new', 16, 16), false)
  MiniTest.expect.equality(model.anchor_valid(hunks, 'new', 26, 26), false)
  -- a file-level comment (no side) is always valid, hunks notwithstanding
  MiniTest.expect.equality(model.anchor_valid(hunks, nil, nil, nil), true)
end

T['§9.4: diff_position for a single-hunk and a multi-hunk file (position = 1-based diff-line index below the first @@)'] = function()
  local r = Repo.new()
  r:commit('Base', { ['f.txt'] = Repo.lines(60) })
  r:commit('Edit', { ['f.txt'] = Repo.edit(11, 'line 11 v2', 50, 'line 50 v2') })

  local full = git_diff(r.dir, r.sha.Base, r.sha.Edit, { '-U3' })
  local lines = vim.split(full, '\n', { plain = true })
  local start
  for i, l in ipairs(lines) do
    if l:match('^@@') then
      start = i
      break
    end
  end
  local diff_lines = {}
  for i = start, #lines do
    table.insert(diff_lines, lines[i])
  end
  -- verified independently against the sandbox's own `position()` helper
  -- (`sandbox/build.js`) on the same shape of diff: one hunk -> pos 5 for
  -- the changed line itself, two hunks -> pos 14 for the second hunk's
  -- changed line (later `@@` headers count as diff lines too)
  MiniTest.expect.equality(model.diff_position(diff_lines, 11), 5)
  MiniTest.expect.equality(model.diff_position(diff_lines, 50), 14)
  -- a line nowhere in the diff (outside every hunk) has no position
  MiniTest.expect.equality(model.diff_position(diff_lines, 5), nil)

  r:destroy()
end

return T

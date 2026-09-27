-- §9.1, §12.6 (phase 6, logic): excerpt relocation, pair-side placement,
-- id generation and unified-diff hunk extraction. Pure review/model.lua,
-- no UI/child nvim involved.
local model = require('diffy.review.model')

local T = MiniTest.new_set()

T['§9.1: relocate finds the excerpt after lines shift above it, updating the anchor'] = function()
  local anchor = { start_line = 10, end_line = 10, excerpt = { 'target line' } }
  -- two lines inserted above the anchor: its content is now at line 12
  local lines = { 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'new1', 'new2', 'target line', 'k' }
  local ok = model.relocate(anchor, lines)
  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(anchor.start_line, 12)
  MiniTest.expect.equality(anchor.end_line, 12)
end

T['§9.1: relocate reports no match (detached) when the anchored lines are deleted'] = function()
  local anchor = { start_line = 10, end_line = 11, excerpt = { 'target line 1', 'target line 2' } }
  local lines = {}
  for i = 1, 20 do
    lines[i] = 'line ' .. i
  end
  local ok = model.relocate(anchor, lines)
  MiniTest.expect.equality(ok, false)
  -- untouched on failure, so callers keep the last-known position
  MiniTest.expect.equality(anchor.start_line, 10)
end

T['§9.1: relocate gives up beyond the +/-20 line window'] = function()
  local lines = {}
  for i = 1, 60 do
    lines[i] = 'line ' .. i
  end
  lines[45] = 'target'
  local anchor = { start_line = 10, end_line = 10, excerpt = { 'target' } }
  MiniTest.expect.equality(model.relocate(anchor, lines), false)
end

T['§9.3: pair_side matches worktree/index/HEAD-resolved-to-sha anchors to the right window'] = function()
  local pair = { left = 'INDEX', right = 'WORKTREE' }
  MiniTest.expect.equality(
    model.pair_side(pair, 'deadbeef', { side = 'old', commit = 'index' }),
    'left'
  )
  MiniTest.expect.equality(
    model.pair_side(pair, 'deadbeef', { side = 'new', commit = 'worktree' }),
    'right'
  )
  -- a HEAD-shown side resolves through head_sha before comparing
  MiniTest.expect.equality(
    model.pair_side({ left = 'HEAD', right = 'INDEX' }, 'deadbeef', { side = 'old', commit = 'deadbeef' }),
    'left'
  )
  -- neither side matches: the pair has since changed, thread isn't shown
  MiniTest.expect.equality(
    model.pair_side(pair, 'deadbeef', { side = 'new', commit = 'cafefeed' }),
    nil
  )
end

T['§9.1: next_thread_id/next_comment_id continue past the highest existing id, ignoring gaps'] = function()
  local threads = {
    { id = 't1', comments = { { id = 'c1' }, { id = 'c3' } } },
    { id = 't3', comments = { { id = 'c2' } } },
  }
  MiniTest.expect.equality(model.next_thread_id(threads), 't4')
  MiniTest.expect.equality(model.next_comment_id(threads), 'c4')
  MiniTest.expect.equality(model.next_thread_id({}), 't1')
end

T['§9.2: summary_text shows the first author, extra-comment count and resolved state'] = function()
  local thread = { comments = { { author = 'alice' }, { author = 'bob' }, { author = 'alice' } }, resolved = true }
  MiniTest.expect.equality(model.summary_text(thread), '\240\159\146\172 alice +2 \194\183 resolved')
  local single = { comments = { { author = 'alice' } }, resolved = false }
  MiniTest.expect.equality(model.summary_text(single), '\240\159\146\172 alice')
end

T['§9.3: find_hunk locates the hunk overlapping an anchor on the requested side'] = function()
  local diff = table.concat({
    '@@ -1,3 +1,3 @@',
    ' a',
    '-b',
    '+b2',
    ' c',
    '@@ -10,2 +10,4 @@',
    ' j',
    '+k1',
    '+k2',
    ' m',
  }, '\n')
  local hunks = model.parse_hunks(diff)
  MiniTest.expect.equality(#hunks, 2)
  local h = model.find_hunk(hunks, 'new', 11, 12)
  MiniTest.expect.equality(h.new_start, 10)
  MiniTest.expect.equality(model.find_hunk(hunks, 'old', 50, 50), nil)
end

return T

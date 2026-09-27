-- §9.1, §12.6 (phase 6, logic): excerpt relocation's +/-20 line search
-- window. Pure review/model.lua, no UI/child nvim involved.
--
-- Everything else review/model.lua's local backend does (relocate finding
-- a shifted/deleted excerpt, pair_side placement, id generation,
-- summary_text, find_hunk's diff-hunk lookup) is proven by the UI
-- scenarios in tests/test_review_local.lua that exercise it through real
-- keys and files (§11.3.4: no separate test of a private helper already
-- covered by a scenario). The +/-20 boundary itself is the one case that
-- fits §11.2's Logic layer: a search-window edge a UI scenario has no
-- natural way to hit deterministically.
local model = require('diffy.review.model')

local T = MiniTest.new_set()

T['§9.1: relocate gives up beyond the +/-20 line window'] = function()
  local lines = {}
  for i = 1, 60 do
    lines[i] = 'line ' .. i
  end
  lines[45] = 'target'
  local anchor = { start_line = 10, end_line = 10, excerpt = { 'target' } }
  MiniTest.expect.equality(model.relocate(anchor, lines), false)
end

return T

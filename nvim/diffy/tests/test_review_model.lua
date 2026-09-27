-- Excerpt relocation's +/-20 line search
-- window. Pure review/model.lua, no UI/child nvim involved.
--
-- Everything else review/model.lua's local backend does (relocate finding
-- a shifted/deleted excerpt, pair_side placement, id generation,
-- summary_text, find_hunk's diff-hunk lookup) is proven by the UI
-- scenarios in tests/test_review_local.lua that exercise it through real
-- keys and files. The +/-20 boundary is tested here because a UI
-- scenario has no natural way to hit it deterministically.
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

return T

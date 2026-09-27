-- Fake GitHub transport (contract §11.4): swapped in for
-- `review/github.lua`'s `M.transport` in every GitHub test, in a child
-- nvim, before opening a session:
--
--   child.lua([[
--     local fake = require('tests.helpers.fake_github')
--     local state = fake.load_fixture('tests/fixtures/github/pr2.json', 2)
--     state.find_pr = { ['sandbox/placement'] = { number = 2, baseRefName = 'base/placement', headRefOid = '865a585...' } }
--     require('diffy.review.github').transport = fake.new(state).transport
--   ]])
--
-- Never mocks git or nvim (contract §11.2) - only this one seam. `state` is
-- plain Lua tables, so a test can hand-build one instead of a recorded
-- fixture for a boundary case (see `tests/test_github_read.lua`'s fold-open
-- case). Part B (push/pull/submit) extends `state` with mutation handlers
-- (a pending review, thread validation) alongside the two read queries
-- already recognized here.
local M = {}

--- Build `{ transport = fun(query, variables, cb) }` backed by `state`:
---   state.find_pr = { [branch] = {number, baseRefName, headRefOid} }
---   state.reads   = { [pr_number] = <recorded `{data=...}` object, as
---                     saved from `gh api graphql --input -`> }
--- Matches which query is being asked by a distinctive substring (the two
--- shapes `review/github.lua` actually sends) - no real GraphQL parser
--- needed, since the fake only has to answer requests this codebase makes.
--- Every call is recorded in `self.calls` for assertions.
function M.new(state)
  local self = { state = state, calls = {} }
  self.transport = function(query, variables, cb)
    table.insert(self.calls, { query = query, variables = variables })
    vim.schedule(function()
      if query:find('pullRequests(headRefName', 1, true) then
        local found = state.find_pr and state.find_pr[variables.h]
        cb({ repository = { pullRequests = { nodes = found and { found } or {} } } }, nil)
        return
      end
      if query:find('reviewThreads(', 1, true) then
        local rec = state.reads and state.reads[variables.n]
        if not rec then
          cb(nil, ('fake_github: no fixture loaded for PR #%d'):format(variables.n))
          return
        end
        cb(rec.data, nil)
        return
      end
      cb(nil, 'fake_github: unrecognized query:\n' .. query)
    end)
  end
  return self
end

--- Load a `gh api graphql --input -`-recorded JSON file (the whole
--- `{data=...}` response) as the read fixture for PR `number`. Returns
--- (and, if not given, creates) `state` so callers can chain in
--- `find_pr`/mutation state alongside it.
function M.load_fixture(path, number, state)
  state = state or {}
  state.reads = state.reads or {}
  local text = table.concat(vim.fn.readfile(path), '\n')
  state.reads[number] = vim.json.decode(text, { luanil = { object = true, array = true } })
  return state
end

return M

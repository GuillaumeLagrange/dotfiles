-- Fake GitHub transport: swapped in for
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
-- Never mocks git or nvim - only this one seam. `state` is
-- plain Lua tables, so a test can hand-build one instead of a recorded
-- fixture for a boundary case (see `tests/test_github_read.lua`'s fold-open
-- case).
--
-- For push/pull/submit/reply/resolve, `state` also takes:
--   state.repo_dir     the fixture repo (for real `git diff` line-tracking
--                      validation, matching the sandbox's own measured
--                      "changed line or ±3 context of merge-base...commit"
--                      rule)
--   state.merge_base   merge-base sha, used the same way
--   state.viewer       viewer login owning the (one, per-user) pending
--                      review; defaults to 'diffy-test-user'
-- Every PR touched by a mutation gets a mutable "db" (deep-copied once from
-- `state.reads[number]`, then mutated in place) so a later `reviewThreads(`
-- read reflects everything the mutations under test did - `state.reads`
-- itself, the recorded fixture, is never modified.
local model = require('diffy.review.model')

local M = {}

local function db_for(state, number)
  state._db = state._db or {}
  if state._db[number] then
    return state._db[number]
  end
  local fixture = state.reads and state.reads[number]
  local pr = fixture and fixture.repository and fixture.repository.pullRequest
  local db = {
    id = pr and pr.id or ('FAKE_PR_%d'):format(number),
    base = pr and pr.baseRefName,
    head = pr and pr.headRefOid,
    title = pr and pr.title,
    body = pr and pr.body,
    conversation = pr and vim.deepcopy(pr.comments.nodes) or {},
    reviews = pr and vim.deepcopy(pr.reviews.nodes) or {},
    threads = pr and vim.deepcopy(pr.reviewThreads.nodes) or {},
    pending = {}, -- viewer login -> {id, commitOID}
    next_id = 1,
  }
  if pr and pr.pendingReviews and pr.pendingReviews.nodes[1] then
    local pid = pr.pendingReviews.nodes[1].id
    db.pending[state.viewer] = { id = pid, commitOID = db.head }
    for _, t in ipairs(db.threads) do
      for _, c in ipairs(t.comments.nodes) do
        if c.pullRequestReview and c.pullRequestReview.id == pid then
          t._pending_review_id = pid
        end
      end
    end
  end
  state._db[number] = db
  return db
end

local function fresh_id(db, prefix)
  db.next_id = db.next_id + 1
  return ('FAKE_%s_%d'):format(prefix, db.next_id)
end

--- Real `git diff -U0 -M merge_base commitOID` hunks for `path` (`-U0`,
--- not `-U3`: `model.anchor_valid` itself adds the ±3 context window - it
--- expects hunks bounded to exactly the changed lines), or nil if `state.repo_dir`/
--- `state.merge_base` aren't configured (a test that never exercises
--- validation, e.g. read-only fixtures, doesn't need them).
local function validation_hunks(state, commit_oid, path)
  if not (state.repo_dir and state.merge_base) then
    return nil
  end
  local res = vim
    .system({ 'git', 'diff', '-U0', '-M', state.merge_base, commit_oid }, { cwd = state.repo_dir, text = true })
    :wait()
  if res.code ~= 0 then
    return nil, 'Path could not be resolved'
  end
  local files = model.parse_diff_files(res.stdout or '')
  for _, f in ipairs(files) do
    if f.old_path == path or f.new_path == path then
      return f.hunks
    end
  end
  return {}, nil -- unchanged file: no hunks, every line is "context"
end

--- `nil, "Line/Path could not be resolved"` if invalid (GitHub accepts a changed line or ±3 context of `merge-base...commitOID`, both
--- sides, file-level always valid); `true` otherwise. Skips the check
--- entirely (always valid) when the state has no repo configured.
local function validate(state, commit_oid, path, side, start_line, end_line)
  if not side then
    return true
  end
  local hunks, path_err = validation_hunks(state, commit_oid, path)
  if hunks == nil then
    if path_err then
      return false, path_err
    end
    return true -- no repo configured: nothing to check against
  end
  if model.anchor_valid(hunks, side, start_line, end_line or start_line) then
    return true
  end
  return false, 'Line could not be resolved'
end

--- Inverse of `model.diff_position`: the new-side line number `position`
--- (1-based, below the file's first `@@`) refers to, for eager remap
--- (GitHub moves a legacy-`position` comment's commit to head immediately
--- when the line is trackable).
local function line_at_position(diff_lines, position)
  local pos, nl = nil, nil
  for _, line in ipairs(diff_lines) do
    local new_start = line:match('^@@ %-%d+,?%d* %+(%d+)')
    if new_start then
      pos = pos and (pos + 1) or 0
      nl = tonumber(new_start) - 1
    elseif pos then
      pos = pos + 1
      if line:sub(1, 1) ~= '-' then
        nl = nl + 1
      end
      if pos == position then
        return nl
      end
    end
  end
  return nil
end

--- Try eagerly remapping a legacy-position comment written on `commit_oid`
--- to `db.head`. Returns `head_sha, head_line` on success,
--- else `nil`.
local function eager_remap(state, db, commit_oid, path, position)
  if not (state.repo_dir and db.head) or commit_oid == db.head then
    return nil
  end
  local res = vim
    .system({ 'git', 'diff', '-U3', '-M', state.merge_base or commit_oid, commit_oid }, { cwd = state.repo_dir, text = true })
    :wait()
  if res.code ~= 0 then
    return nil
  end
  -- recover the new_line the legacy `position` pointed at, then forward-map
  -- it from `commit_oid` to `head` via a plain two-file diff.
  local lines = vim.split(res.stdout or '', '\n', { plain = true })
  local start_i
  for i, l in ipairs(lines) do
    if l:match('^diff %-%-git') then
      if start_i then
        break
      end
      local a, b = l:match('^diff %-%-git a/(.-) b/(.*)$')
      if a == path or b == path then
        start_i = i
      end
    end
  end
  if not start_i then
    return nil
  end
  local section = {}
  for i = start_i, #lines do
    if i > start_i and lines[i]:match('^diff %-%-git') then
      break
    end
    table.insert(section, lines[i])
  end
  local orig_line = line_at_position(section, position)
  if not orig_line then
    return nil
  end
  local track = vim.system({ 'git', 'diff', '-U0', '-M', commit_oid, db.head }, { cwd = state.repo_dir, text = true }):wait()
  if track.code ~= 0 then
    return nil
  end
  local files = model.parse_diff_files(track.stdout or '')
  local hunks = {}
  for _, f in ipairs(files) do
    if f.old_path == path or f.new_path == path then
      hunks = f.hunks
      break
    end
  end
  local mapped = model.map_line(hunks, orig_line)
  if not mapped then
    return nil
  end
  return db.head, mapped
end

local function thread_node(id, path, side, first_comment)
  return { id = id, isResolved = false, path = path, diffSide = side, comments = { nodes = { first_comment } } }
end

--- Build `{ transport = fun(query, variables, cb) }` backed by `state`.
--- Matches which query/mutation is being asked by a distinctive substring
--- (the exact shapes this codebase sends) - no real GraphQL parser needed.
--- Every call is recorded in `self.calls` for assertions.
function M.new(state)
  state.viewer = state.viewer or 'diffy-test-user'
  local self = { state = state, calls = {} }

  local function respond(cb, data)
    vim.schedule(function()
      cb(data, nil)
    end)
  end
  local function fail(cb, message)
    vim.schedule(function()
      cb(nil, message)
    end)
  end

  self.transport = function(query, variables, cb)
    table.insert(self.calls, { query = query, variables = variables })

    if query:find('pullRequests(headRefName', 1, true) then
      local found = state.find_pr and state.find_pr[variables.h]
      respond(cb, { repository = { pullRequests = { nodes = found and { found } or {} } } })
      return
    end

    if query:find('reviewThreads(', 1, true) then
      local db = db_for(state, variables.n)
      local pending_nodes = {}
      for _, p in pairs(db.pending) do
        for _, t in ipairs(db.threads) do
          if t._pending_review_id == p.id then
            for _, c in ipairs(t.comments.nodes) do
              if c.pullRequestReview and c.pullRequestReview.id == p.id then
                table.insert(pending_nodes, c)
              end
            end
          end
        end
      end
      respond(cb, {
        repository = {
          pullRequest = {
            id = db.id,
            number = variables.n,
            title = db.title,
            body = db.body,
            baseRefName = db.base,
            headRefOid = db.head,
            author = { login = 'diffy-fixture-author' },
            comments = { nodes = db.conversation },
            reviews = { nodes = db.reviews },
            pendingReviews = { nodes = db.pending[state.viewer] and { { id = db.pending[state.viewer].id, comments = { nodes = pending_nodes } } } or {} },
            reviewThreads = { pageInfo = { hasNextPage = false, endCursor = nil }, nodes = db.threads },
          },
        },
      })
      return
    end

    if query:find('deletePullRequestReview(', 1, true) then
      for number, db in pairs(state._db or {}) do
        for viewer, p in pairs(db.pending) do
          if p.id == variables.id then
            db.pending[viewer] = nil
            -- Real GitHub deletes only *this review's own* comments, not
            -- whole threads - a thread with a surviving published comment
            -- (e.g. a pending reply on an otherwise-published thread)
            -- keeps its id and its other comments.
            for i = #db.threads, 1, -1 do
              local t = db.threads[i]
              local kept = {}
              for _, c in ipairs(t.comments.nodes) do
                if not (c.pullRequestReview and c.pullRequestReview.id == p.id) then
                  table.insert(kept, c)
                end
              end
              t.comments.nodes = kept
              if t._pending_review_id == p.id then
                t._pending_review_id = nil
              end
              if #kept == 0 then
                table.remove(db.threads, i)
              end
            end
            respond(cb, { deletePullRequestReview = { clientMutationId = nil } })
            return
          end
        end
      end
      fail(cb, 'no such pending review')
      return
    end

    if query:find('addPullRequestReviewThreadReply(', 1, true) then
      for _, db in pairs(state._db or {}) do
        for _, t in ipairs(db.threads) do
          if t.id == variables.t then
            local id = fresh_id(db, 'COMMENT')
            table.insert(t.comments.nodes, {
              id = id,
              author = { login = state.viewer },
              body = variables.b,
              createdAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
              diffHunk = '',
              line = t.comments.nodes[1].line,
              originalLine = t.comments.nodes[1].originalLine,
              startLine = nil,
              originalStartLine = nil,
              commit = t.comments.nodes[1].commit,
              originalCommit = t.comments.nodes[1].originalCommit,
              pullRequestReview = { id = variables.r },
            })
            respond(cb, { addPullRequestReviewThreadReply = { comment = { id = id } } })
            return
          end
        end
      end
      fail(cb, 'no such thread')
      return
    end

    if query:find('addPullRequestReviewComment(', 1, true) then
      local db
      for number, d in pairs(state._db or {}) do
        for _, p in pairs(d.pending) do
          if p.id == variables.r then
            db = d
          end
        end
      end
      if not db then
        fail(cb, 'no such pending review')
        return
      end
      local orig_line
      if state.repo_dir and state.merge_base then
        local res = vim
          .system({ 'git', 'diff', '-U3', '-M', state.merge_base, variables.c }, { cwd = state.repo_dir, text = true })
          :wait()
        local lines = vim.split(res.stdout or '', '\n', { plain = true })
        local start_i
        for i, l in ipairs(lines) do
          if l:match('^diff %-%-git') then
            if start_i then
              break
            end
            local a, b = l:match('^diff %-%-git a/(.-) b/(.*)$')
            if a == variables.p or b == variables.p then
              start_i = i
            end
          end
        end
        if start_i then
          local sect = {}
          for i = start_i, #lines do
            if i > start_i and lines[i]:match('^diff %-%-git') then
              break
            end
            table.insert(sect, lines[i])
          end
          orig_line = line_at_position(sect, variables.pos)
        end
      end
      local ok, err = validate(state, variables.c, variables.p, 'new', orig_line, orig_line)
      if not ok then
        fail(cb, err)
        return
      end
      local id = fresh_id(db, 'COMMENT')
      local commit, line = variables.c, orig_line
      local remapped_commit, remapped_line = eager_remap(state, db, variables.c, variables.p, variables.pos)
      if remapped_commit then
        commit, line = remapped_commit, remapped_line
      end
      local first = {
        id = id,
        author = { login = state.viewer },
        body = variables.b,
        createdAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        diffHunk = '',
        line = line,
        originalLine = orig_line,
        startLine = nil,
        originalStartLine = nil,
        commit = { oid = commit },
        originalCommit = { oid = variables.c },
        pullRequestReview = { id = variables.r },
      }
      local tnode = thread_node(fresh_id(db, 'THREAD'), variables.p, 'RIGHT', first)
      tnode._pending_review_id = variables.r
      table.insert(db.threads, tnode)
      respond(cb, { addPullRequestReviewComment = { comment = { id = id } } })
      return
    end

    if query:find('addPullRequestReviewThread(', 1, true) then
      local db
      for _, d in pairs(state._db or {}) do
        for _, p in pairs(d.pending) do
          if p.id == variables.r then
            db = d
          end
        end
      end
      if not db then
        fail(cb, 'no such pending review')
        return
      end
      local id = fresh_id(db, 'COMMENT')
      local first = {
        id = id,
        author = { login = state.viewer },
        body = variables.b,
        createdAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        diffHunk = '',
        line = variables.l,
        originalLine = variables.l,
        startLine = variables.sl,
        originalStartLine = variables.sl,
        commit = { oid = db.head },
        originalCommit = { oid = db.head },
        pullRequestReview = { id = variables.r },
      }
      local tid = fresh_id(db, 'THREAD')
      local tnode = thread_node(tid, variables.p, variables.s, first)
      tnode._pending_review_id = variables.r
      table.insert(db.threads, tnode)
      respond(cb, { addPullRequestReviewThread = { thread = { id = tid } } })
      return
    end

    if query:find('addPullRequestReview(', 1, true) then
      local number
      for n, d in pairs(state._db or {}) do
        if d.id == variables.pr then
          number = n
        end
      end
      if not number then
        for n in pairs(state.reads or {}) do
          number = n
          break
        end
      end
      local db = db_for(state, number)
      for _, input in ipairs(variables.t or {}) do
        local ok, err = validate(state, variables.c, input.path, input.side and (input.side == 'LEFT' and 'old' or 'new'), input.startLine or input.line, input.line)
        if not ok then
          fail(cb, err)
          return
        end
      end
      local review_id = fresh_id(db, 'REVIEW')
      db.pending[state.viewer] = { id = review_id, commitOID = variables.c }
      for _, input in ipairs(variables.t or {}) do
        local id = fresh_id(db, 'COMMENT')
        local first = {
          id = id,
          author = { login = state.viewer },
          body = input.body,
          createdAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
          diffHunk = '',
          line = input.line,
          originalLine = input.line,
          startLine = input.startLine,
          originalStartLine = input.startLine,
          commit = { oid = variables.c },
          originalCommit = { oid = variables.c },
          pullRequestReview = { id = review_id },
        }
        local tnode = thread_node(fresh_id(db, 'THREAD'), input.path, input.side, first)
        tnode._pending_review_id = review_id
        table.insert(db.threads, tnode)
      end
      respond(cb, { addPullRequestReview = { pullRequestReview = { id = review_id } } })
      return
    end

    if query:find('submitPullRequestReview(', 1, true) then
      for _, db in pairs(state._db or {}) do
        for viewer, p in pairs(db.pending) do
          if p.id == variables.r then
            db.pending[viewer] = nil
            for _, t in ipairs(db.threads) do
              if t._pending_review_id == p.id then
                t._pending_review_id = nil
                for _, c in ipairs(t.comments.nodes) do
                  if c.pullRequestReview and c.pullRequestReview.id == p.id then
                    c.pullRequestReview = { id = p.id }
                  end
                end
              end
            end
            table.insert(db.reviews, {
              id = p.id,
              author = { login = viewer },
              state = variables.e,
              body = variables.b,
              submittedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
              commit = { oid = p.commitOID },
            })
            respond(cb, { submitPullRequestReview = { pullRequestReview = { id = p.id } } })
            return
          end
        end
      end
      fail(cb, 'no such pending review')
      return
    end

    if query:find('unresolveReviewThread(', 1, true) then
      for _, db in pairs(state._db or {}) do
        for _, t in ipairs(db.threads) do
          if t.id == variables.t then
            t.isResolved = false
            respond(cb, { unresolveReviewThread = { thread = { isResolved = false } } })
            return
          end
        end
      end
      fail(cb, 'no such thread')
      return
    end

    if query:find('resolveReviewThread(', 1, true) then
      for _, db in pairs(state._db or {}) do
        for _, t in ipairs(db.threads) do
          if t.id == variables.t then
            t.isResolved = true
            respond(cb, { resolveReviewThread = { thread = { isResolved = true } } })
            return
          end
        end
      end
      fail(cb, 'no such thread')
      return
    end

    fail(cb, 'fake_github: unrecognized query:\n' .. query)
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
  state.reads[number] = vim.json.decode(text, { luanil = { object = true, array = true } }).data
  return state
end

return M

-- GitHub review backend (contract §9.4): the PR of the checked-out branch.
-- This phase (7A) owns the *read* side - threads/reviews/description/
-- pending review, placement (line tracking across commits) and `:Diffy
-- pr`'s readiness check. Push/pull/submit/reply/resolve (phase 7B) are
-- added alongside `M.load`/`M.save` below, reusing this file's transport,
-- `M.owner_repo`, and `review/model.lua`'s `map_range`/`anchor_valid`/
-- `diff_position`.
local model = require('diffy.review.model')
local run = require('diffy.git.run')
local repo = require('diffy.git.repo')

local M = {}

M.name = 'github'
M.capabilities = { resolve = true, suggestions = true }

--- Persistence scope key (contract §9.4 draft path `pr-<number>.json`,
--- phase 7B). Read-only today: nothing is persisted yet, but the backend
--- interface (architecture.md, phase 6) requires this.
function M.branch(session)
  return ('pr-%d'):format(session.range.pr_number)
end

local cached_author
--- Viewer's GitHub login, cached for the process lifetime (mirrors
--- `review/local.lua`'s `M.author` - a one-shot call, not on the render
--- path).
function M.author(_root)
  if cached_author then
    return cached_author
  end
  local res = vim.system({ 'gh', 'api', 'user', '-q', '.login' }, { text = true }):wait()
  cached_author = vim.trim((res.code == 0 and res.stdout) or 'unknown')
  return cached_author
end

-- ---------------------------------------------------------------------
-- transport (contract §9.4/§11.4): the one seam every gh request goes
-- through. Tests replace this module field with
-- `tests/helpers/fake_github.lua`'s function before opening a session -
-- never by mocking git or nvim itself.

--- `gh api graphql --input -` with `{query, variables}` on stdin (avoids
--- `-f` quoting of multi-line bodies, AGENTS.md). `cb(data, err)`: `data`
--- is the response's `.data` object on success.
function M.transport(query, variables, cb)
  local input = vim.json.encode({ query = query, variables = variables })
  return vim.system({ 'gh', 'api', 'graphql', '--input', '-' }, { stdin = input, text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        cb(nil, vim.trim((res.stderr ~= '' and res.stderr) or res.stdout or ('gh exited %d'):format(res.code)))
        return
      end
      local ok, decoded = pcall(vim.json.decode, res.stdout or '', { luanil = { object = true, array = true } })
      if not ok then
        cb(nil, 'invalid JSON from `gh api graphql`')
        return
      end
      if decoded.errors then
        cb(nil, vim.json.encode(decoded.errors))
        return
      end
      cb(decoded.data, nil)
    end)
  end)
end

--- `owner`/`name` of the `origin` remote (no `gh` call - a plain URL
--- parse, so it's independently testable and doesn't need the fake).
--- `cb(owner, name, err)`.
function M.owner_repo(root, cb)
  run.git({ 'remote', 'get-url', 'origin' }, {
    cwd = root,
    notify_on_error = false,
    on_exit = function(res)
      if res.code ~= 0 then
        cb(nil, nil, 'no `origin` remote')
        return
      end
      local url = vim.trim(res.stdout or '')
      local owner, name = url:match('[:/]([%w_.%-]+)/([%w_.%-]-)%.git$')
      if not owner then
        owner, name = url:match('[:/]([%w_.%-]+)/([%w_.%-]+)$')
      end
      if not owner then
        cb(nil, nil, 'could not parse owner/repo from `' .. url .. '`')
        return
      end
      cb(owner, name, nil)
    end,
  })
end

local FIND_PR_QUERY = [[
query($o: String!, $r: String!, $h: String!) {
  repository(owner: $o, name: $r) {
    pullRequests(headRefName: $h, states: [OPEN], first: 5) {
      nodes { number baseRefName headRefOid }
    }
  }
}
]]

--- The open PR whose head is the current branch, or `(nil, err)`. `cb(pr,
--- err)`, `pr = { number, baseRefName, headRefOid }`.
function M.find_pr(root, cb)
  M.owner_repo(root, function(owner, name, err)
    if not owner then
      cb(nil, err)
      return
    end
    run.git({ 'branch', '--show-current' }, {
      cwd = root,
      notify_on_error = false,
      on_exit = function(res)
        local branch = vim.trim(res.stdout or '')
        if res.code ~= 0 or branch == '' then
          cb(nil, 'not on a branch (detached HEAD)')
          return
        end
        M.transport(FIND_PR_QUERY, { o = owner, r = name, h = branch }, function(data, gerr)
          if not data then
            cb(nil, gerr)
            return
          end
          local nodes = data.repository.pullRequests.nodes
          if #nodes == 0 then
            cb(nil, ('no open PR found for branch `%s`'):format(branch))
            return
          end
          cb(nodes[1], nil)
        end)
      end,
    })
  end)
end

--- `:Diffy pr`'s refusal check (contract §4): the tree must be clean and
--- local HEAD must equal the PR head on GitHub. `cb(ok, reason)`; `reason`
--- is nil on success, else names what's wrong (dirty tree, unpushed
--- commits, behind remote, or - when ancestry can't be determined locally,
--- e.g. the PR head was never fetched - a generic mismatch message).
function M.pr_readiness(root, head_sha, pr_head_sha, clean, cb)
  if not clean then
    cb(false, 'the tree is dirty (tracked changes present, staged or unstaged) - commit or stash them first')
    return
  end
  if head_sha == pr_head_sha then
    cb(true, nil)
    return
  end
  run.git({ 'merge-base', '--is-ancestor', head_sha, pr_head_sha }, {
    cwd = root,
    notify_on_error = false,
    on_exit = function(res)
      if res.code == 0 then
        cb(false, 'local HEAD is behind the PR head on GitHub - pull first')
        return
      end
      run.git({ 'merge-base', '--is-ancestor', pr_head_sha, head_sha }, {
        cwd = root,
        notify_on_error = false,
        on_exit = function(res2)
          if res2.code == 0 then
            cb(false, 'local HEAD has unpushed commits - push first')
          else
            cb(
              false,
              ('local HEAD (%s) does not match the PR head on GitHub (%s)'):format(
                head_sha:sub(1, 7),
                pr_head_sha:sub(1, 7)
              )
            )
          end
        end,
      })
    end,
  })
end

-- ---------------------------------------------------------------------
-- read (contract §9.4): threads, reviews, description/conversation, the
-- viewer's own pending review. One query, paginated over `reviewThreads`
-- (the only connection realistically deep enough to exceed one page); the
-- PR-level fields (comments/reviews/pendingReviews) are only kept from the
-- first page, since they're cheap and don't need their own pagination for
-- the PR sizes diffy targets (contract §13's "large PRs" risk).

local READ_QUERY = [[
query($o: String!, $r: String!, $n: Int!, $cursor: String) {
  repository(owner: $o, name: $r) {
    pullRequest(number: $n) {
      number
      title
      body
      baseRefName
      headRefOid
      author { login }
      comments(first: 100) {
        nodes { author { login } body createdAt }
      }
      reviews(first: 100) {
        nodes { id author { login } state body submittedAt commit { oid } }
      }
      pendingReviews: reviews(states: [PENDING], first: 5) {
        nodes {
          id
          comments(first: 100) {
            nodes {
              id path line originalLine startLine originalStartLine body
              commit { oid } originalCommit { oid }
            }
          }
        }
      }
      reviewThreads(first: 50, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          path
          diffSide
          comments(first: 50) {
            nodes {
              id
              author { login }
              body
              createdAt
              diffHunk
              line
              originalLine
              startLine
              originalStartLine
              commit { oid }
              originalCommit { oid }
              pullRequestReview { id }
            }
          }
        }
      }
    }
  }
}
]]

local function paginate_threads(owner, name, number, cb)
  local acc = {}
  local meta
  local function step(cursor)
    M.transport(READ_QUERY, { o = owner, r = name, n = number, cursor = cursor }, function(data, err)
      if not data then
        cb(nil, nil, err)
        return
      end
      local pr = data.repository and data.repository.pullRequest
      if not pr then
        cb(nil, nil, ('PR #%d not found'):format(number))
        return
      end
      if not meta then
        meta = {
          number = pr.number,
          title = pr.title,
          body = pr.body,
          base = pr.baseRefName,
          head_sha = pr.headRefOid,
          conversation = {},
          reviews = {},
          pending = nil,
        }
        for _, c in ipairs(pr.comments.nodes) do
          table.insert(meta.conversation, { author = c.author and c.author.login, body = c.body, created_at = c.createdAt })
        end
        for _, rv in ipairs(pr.reviews.nodes) do
          table.insert(meta.reviews, {
            id = rv.id,
            author = rv.author and rv.author.login,
            state = rv.state,
            body = rv.body,
            submitted_at = rv.submittedAt,
            commit = rv.commit and rv.commit.oid,
          })
        end
        meta.pending = pr.pendingReviews.nodes[1]
      end
      vim.list_extend(acc, pr.reviewThreads.nodes)
      if pr.reviewThreads.pageInfo.hasNextPage then
        step(pr.reviewThreads.pageInfo.endCursor)
      else
        cb(acc, meta, nil)
      end
    end)
  end
  step(nil)
end

--- `git cat-file --batch-check` for every distinct sha in `shas`: which
--- ones are present locally (contract §13 - a force-pushed-away commit may
--- not be). `cb(exists)`, `exists[sha] == true` for present objects.
local function existing_shas(root, shas, cb)
  local uniq = {}
  for _, s in ipairs(shas) do
    if s then
      uniq[s] = true
    end
  end
  local list = {}
  for s in pairs(uniq) do
    table.insert(list, s)
  end
  if #list == 0 then
    cb({})
    return
  end
  vim.system(
    { 'git', 'cat-file', '--batch-check=%(objectname) %(objecttype)' },
    { cwd = root, stdin = table.concat(list, '\n') .. '\n', text = true },
    function(res)
      vim.schedule(function()
        local exists = {}
        for _, line in ipairs(vim.split(res.stdout or '', '\n', { plain = true })) do
          local sha, kind = line:match('^(%x+) (%a+)')
          if sha and kind ~= 'missing' then
            exists[sha] = true
          end
        end
        cb(exists)
      end)
    end
  )
end

--- Source anchor (contract §9.4): the first comment's `commit`/`line` if
--- that commit exists locally, else `originalCommit`/`originalLine`, else
--- `nil` (neither exists locally - §13, only `:Diffy threads` lists it).
--- For an old-side thread the chosen line is already merge-base-relative
--- (GitHub fact, AGENTS.md); `commit` only decides *which* of the two line
--- values is current, tracking itself always starts from merge-base.
local function source_anchor(first, exists)
  local commit, line, start_line = first.commit and first.commit.oid, first.line, first.startLine
  if commit and exists[commit] and line then
    return commit, start_line or line, line
  end
  local ocommit, oline, ostart = first.originalCommit and first.originalCommit.oid, first.originalLine, first.originalStartLine
  if ocommit and exists[ocommit] then
    return ocommit, ostart or oline, oline
  end
  return nil
end

--- Build one `Thread` (contract §9.1/§9.4) from a raw `reviewThreads` node.
local function build_thread(node, exists)
  local comments = {}
  for _, c in ipairs(node.comments.nodes) do
    table.insert(comments, {
      id = c.id,
      author = c.author and c.author.login or 'unknown',
      body = c.body,
      created_at = c.createdAt,
      state = 'published',
    })
  end
  local first = node.comments.nodes[1]
  local source_commit, start_line, end_line = source_anchor(first, exists)
  local side
  if first.line == nil and first.originalLine == nil then
    side = nil -- file-level: subjectType FILE, no line at all (contract §9.4)
  else
    side = node.diffSide == 'LEFT' and 'old' or 'new'
  end
  return {
    id = node.id,
    backend = 'github',
    review_id = first.pullRequestReview and first.pullRequestReview.id,
    resolved = node.isResolved,
    comments = comments,
    anchor = {
      path = node.path,
      side = side,
      start_line = start_line,
      end_line = end_line,
      commit = source_commit,
      excerpt = nil,
    },
    -- computed below, once HEAD's tracking is known (M.refresh)
    outdated = false,
    _has_source = source_commit ~= nil,
  }
end

-- ---------------------------------------------------------------------
-- placement (contract §9.4): line tracking via `git diff -M X Y` hunks,
-- pre-computed for every (source, target) pair a session's log could
-- possibly show, so `M.place` (called synchronously from the render
-- pipeline, `review/ui.lua`'s `M.decorate`) only ever does table lookups.

--- Every `(X, Y)` pair `M.place` might need for `session.entries`
--- (contract §9.4: new-side tracks to whichever commit is on the right;
--- old-side always tracks from merge-base to whichever commit is on the
--- left - `C^` for a single-commit view, merge-base itself, trivially, for
--- the full-PR view).
local function diff_pairs_needed(threads, entries, merge_base)
  local set = {}
  local function add(x, y)
    if x and y and x ~= y then
      set[x .. '\30' .. y] = true
    end
  end
  local new_targets, old_targets = {}, { merge_base }
  for _, e in ipairs(entries) do
    table.insert(new_targets, e.sha)
    table.insert(old_targets, e.sha .. '^')
  end
  for _, t in ipairs(threads) do
    if t._has_source then
      if t.anchor.side == 'new' then
        for _, y in ipairs(new_targets) do
          add(t.anchor.commit, y)
        end
      elseif t.anchor.side == 'old' then
        for _, y in ipairs(old_targets) do
          add(merge_base, y)
        end
      end
    end
  end
  return set
end

local function build_diff_cache(root, pairs_set, cb)
  local keys = {}
  for k in pairs(pairs_set) do
    table.insert(keys, k)
  end
  local cache = {}
  local remaining = #keys
  if remaining == 0 then
    cb(cache)
    return
  end
  for _, key in ipairs(keys) do
    local x, y = key:match('^(.-)\30(.*)$')
    run.git({ 'diff', '-M', '-U0', x, y }, {
      cwd = root,
      notify_on_error = false,
      on_exit = function(res)
        cache[key] = res.code == 0 and model.parse_diff_files(res.stdout or '') or {}
        remaining = remaining - 1
        if remaining == 0 then
          cb(cache)
        end
      end,
    })
  end
end

--- Where `thread` shows in `left`/`right` (rev pair, e.g. `session.pair`)
--- for `path` (e.g. `session.current_path`), or `nil` if it's hidden in
--- this view. Pulled out of `M.place` so `:Diffy threads`'s "commits this
--- thread is visible in" (`M.visible_in`) can probe other views too.
local function place_at(review, thread, left, right, path)
  local anchor = thread.anchor
  if anchor.path ~= path or not thread._has_source then
    return nil
  end
  if not anchor.side then
    -- file-level (contract §9.4/AGENTS.md): always valid, shown pinned at
    -- the top of the new side.
    return { win = 'right', start_line = 1, end_line = 1 }
  end
  local win = anchor.side == 'old' and 'left' or 'right'
  local target = anchor.side == 'old' and left or right
  local source = anchor.side == 'old' and review.merge_base or anchor.commit
  if target == source then
    return { win = win, start_line = anchor.start_line, end_line = anchor.end_line }
  end
  local files = review._diff_cache[source .. '\30' .. target]
  if not files then
    return nil
  end
  local _, hunks = model.diff_file_hunks(files, anchor.path)
  local s, e = model.map_range(hunks, anchor.start_line, anchor.end_line)
  if not s then
    return nil
  end
  return { win = win, start_line = s, end_line = e }
end

--- `review/ui.lua`'s backend placement hook (architecture.md, phase 6/7):
--- where `thread` shows in the session's *current* pair/file, or `nil`.
function M.place(session, thread)
  return place_at(session.review, thread, session.pair.left, session.pair.right, session.current_path)
end

--- `:Diffy threads`: every commit (by subject, newest first) `thread` is
--- visible in, plus `'head'` for the full-PR view - contract §9.4's
--- "`:Diffy threads` always lists everything, with the commits each thread
--- is visible in".
function M.visible_in(session, thread)
  local review = session.review
  local out = {}
  if place_at(review, thread, review.merge_base, session.head_sha, thread.anchor.path) then
    table.insert(out, 'head')
  end
  for _, e in ipairs(session.entries) do
    if e.kind == 'commit' and not e.merge then
      if place_at(review, thread, e.sha .. '^', e.sha, thread.anchor.path) then
        table.insert(out, e.sha:sub(1, 7))
      end
    end
  end
  return out
end

--- (Re)fetch everything read-related for `session` (contract §9.4: cached
--- per session, refreshed with `R`). Called from `init.lua`'s `M.build`
--- for a `kind='pr'` session, before the render pipeline's final render
--- step. `cb()` always runs, even on failure (a notify already fired).
--- Every continuation checks `session.closed` first (teardown may have run
--- mid-flight - `:Diffy close` while a fetch is in progress) so nothing
--- downstream touches a torn-down session's wiped buffers/closed windows.
function M.refresh(session, cb)
  local root = session.root
  M.owner_repo(root, function(owner, name, err)
    if session.closed then
      return
    end
    if not owner then
      vim.notify('diffy: ' .. err, vim.log.levels.ERROR)
      cb()
      return
    end
    paginate_threads(owner, name, session.range.pr_number, function(nodes, meta, rerr)
      if session.closed then
        return
      end
      if not nodes then
        vim.notify('diffy: ' .. tostring(rerr), vim.log.levels.ERROR)
        cb()
        return
      end
      repo.merge_base(root, session.range.base, session.head_sha, function(mb)
        if session.closed then
          return
        end
        local shas = {}
        for _, n in ipairs(nodes) do
          local first = n.comments.nodes[1]
          table.insert(shas, first.commit and first.commit.oid)
          table.insert(shas, first.originalCommit and first.originalCommit.oid)
        end
        existing_shas(root, shas, function(exists)
          if session.closed then
            return
          end
          local threads = {}
          for _, n in ipairs(nodes) do
            table.insert(threads, build_thread(n, exists))
          end
          local pairs_set = diff_pairs_needed(threads, session.entries, mb)
          build_diff_cache(root, pairs_set, function(cache)
            if session.closed then
              return
            end
            local review = session.review or {}
            review.backend = M
            review.branch = M.branch(session)
            review.threads = threads
            review.inline = review.inline == nil and true or review.inline
            review.pr = meta
            review.merge_base = mb
            review._diff_cache = cache
            session.review = review
            -- outdated (contract §9.4): computed by diffy, not GitHub's own
            -- `isOutdated` - can this thread's source be tracked to HEAD?
            for _, t in ipairs(threads) do
              t.outdated = not t._has_source or place_at(review, t, mb, session.head_sha, t.anchor.path) == nil
            end
            cb()
          end)
        end)
      end)
    end)
  end)
end

return M

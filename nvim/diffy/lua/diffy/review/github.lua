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
local parse = require('diffy.git.parse')
local store = require('diffy.review.store')
local local_backend = require('diffy.review.local')
local prompt = require('diffy.prompt')

local M = {}

M.name = 'github'
M.capabilities = { resolve = true, suggestions = true }

--- Persistence scope key threaded through `review/ui.lua` as
--- `session.review.branch` (an opaque label, `pr-<number>`) - the actual
--- file path (contract §9.4 draft path `.git/diffy/<branch>/pr-<number>.json`,
--- `<branch>` there being the checked-out *git* branch) is built by
--- `pr_json_path` below instead, via `review/local.lua`'s own `M.branch`.
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
-- persistence (contract §9.4 Writing): local drafts survive restarts at
-- `.git/diffy/<branch>/pr-<number>.json`. Only `draft` (never pushed) and
-- `pending` (pushed once, then re-anchored to its original commit/line by
-- `:Diffy review pull`) comments are ever persisted - `published`/`sent`
-- content is always re-fetched fresh from GitHub instead of duplicated
-- locally.
local function pr_json_path(session)
  return store.dir(session.gitdir, local_backend.branch(session)) .. ('/pr-%d.json'):format(session.range.pr_number)
end

function M.load(session, _branch)
  local data = store.load(pr_json_path(session))
  return (data and data.threads) or {}
end

function M.save(session, _branch, threads)
  local keep = {}
  for _, t in ipairs(threads) do
    local comments = {}
    for _, c in ipairs(t.comments) do
      if c.state == 'draft' or c.state == 'pending' then
        table.insert(comments, { id = c.id, author = c.author, body = c.body, created_at = c.created_at, state = c.state })
      end
    end
    if #comments > 0 then
      table.insert(keep, { id = t.id, backend = t.backend, anchor = t.anchor, comments = comments, resolved = t.resolved })
    end
  end
  store.save(pr_json_path(session), { threads = keep })
end

--- Merge persisted local drafts into freshly-fetched `threads` (mutated in
--- place, called from `M.refresh`), matched by real GitHub thread/comment
--- id where one exists:
--- - a persisted thread whose `id` matches a live one gets its `anchor`
---   reclaimed (contract §9.4 pull: "restoring...from originalCommit/
---   originalLine") and any comment not already present appended (a draft
---   reply, or a comment re-marked `draft` by a pull); a comment already
---   present just has its `state`/`body` updated in place (a pull
---   re-marking an already-`pending` comment `draft` again, or a local
---   edit of one).
--- - a persisted thread with no live match is a brand-new, never-pushed
---   local draft (a `t<N>` id, from `model.next_thread_id`) - inserted
---   as-is, `_has_source` forced true (its anchor is, by construction,
---   always local).
function M.merge_drafts(session, threads)
  local persisted = M.load(session, M.branch(session))
  local by_id = {}
  for _, t in ipairs(threads) do
    by_id[t.id] = t
  end
  for _, pt in ipairs(persisted) do
    local live = by_id[pt.id]
    if live then
      live.anchor = pt.anchor
      local have = {}
      for _, c in ipairs(live.comments) do
        have[c.id] = c
      end
      for _, c in ipairs(pt.comments) do
        local existing = have[c.id]
        if existing then
          existing.state = c.state
          existing.body = c.body
        else
          table.insert(live.comments, c)
        end
      end
    else
      pt._has_source = true
      table.insert(threads, pt)
      by_id[pt.id] = pt
    end
  end
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
      id
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
          id = pr.id,
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
--- `pending_review_id`, when given, marks any comment belonging to it
--- `state = 'pending'` (still on the viewer's own unsubmitted review - a
--- GitHub fact, AGENTS.md: pending threads/comments already appear in
--- `reviewThreads`, lazily, alongside submitted ones) rather than
--- `'published'`.
local function build_thread(node, exists, pending_review_id)
  local comments = {}
  for _, c in ipairs(node.comments.nodes) do
    local pending = pending_review_id and c.pullRequestReview and c.pullRequestReview.id == pending_review_id
    table.insert(comments, {
      id = c.id,
      author = c.author and c.author.login or 'unknown',
      body = c.body,
      created_at = c.createdAt,
      state = pending and 'pending' or 'published',
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
    -- raw per-comment fields (originalCommit/originalLine/pullRequestReview) -
    -- `M.pull`'s (phase 7B) source for rebuilding original-anchored drafts;
    -- `comments` above only keeps the trimmed display shape.
    _raw_comments = node.comments.nodes,
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
          local pending_id = meta.pending and meta.pending.id
          for _, n in ipairs(nodes) do
            table.insert(threads, build_thread(n, exists, pending_id))
          end
          M.merge_drafts(session, threads)
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

-- ---------------------------------------------------------------------
-- writing (contract §9.4): push/pull/submit, reply (via `review/ui.lua`'s
-- generic `M.reply`, unlocked automatically now that `M.save` exists),
-- resolve/unresolve.

local MUTATIONS = {
  delete_review = [[mutation($id: ID!) { deletePullRequestReview(input: {pullRequestReviewId: $id}) { clientMutationId } }]],
  create_review = [[mutation($pr: ID!, $c: GitObjectID!, $t: [DraftPullRequestReviewThread]) { addPullRequestReview(input: {pullRequestId: $pr, commitOID: $c, threads: $t}) { pullRequestReview { id } } }]],
  add_comment = [[mutation($r: ID!, $c: GitObjectID!, $p: String!, $pos: Int!, $b: String!) { addPullRequestReviewComment(input: {pullRequestReviewId: $r, commitOID: $c, path: $p, position: $pos, body: $b}) { comment { id } } }]],
  add_thread = [[mutation($r: ID!, $p: String!, $l: Int!, $s: DiffSide!, $sl: Int, $ss: DiffSide, $b: String!) { addPullRequestReviewThread(input: {pullRequestReviewId: $r, path: $p, line: $l, side: $s, startLine: $sl, startSide: $ss, body: $b}) { thread { id } } }]],
  add_reply = [[mutation($r: ID!, $t: ID!, $b: String!) { addPullRequestReviewThreadReply(input: {pullRequestReviewId: $r, pullRequestReviewThreadId: $t, body: $b}) { comment { id } } }]],
  submit = [[mutation($r: ID!, $e: PullRequestReviewEvent!, $b: String) { submitPullRequestReview(input: {pullRequestReviewId: $r, event: $e, body: $b}) { pullRequestReview { id } } }]],
  resolve = [[mutation($t: ID!) { resolveReviewThread(input: {threadId: $t}) { thread { isResolved } } }]],
  unresolve = [[mutation($t: ID!) { unresolveReviewThread(input: {threadId: $t}) { thread { isResolved } } }]],
}

--- Resolve/unresolve `thread` directly on GitHub (contract §9.4: "not part
--- of the draft" - no `backend.save`, no draft state involved). `cb(ok)`.
function M.resolve_thread(session, thread, resolved, cb)
  M.transport(resolved and MUTATIONS.resolve or MUTATIONS.unresolve, { t = thread.id }, function(data, err)
    if not data then
      vim.notify('diffy: ' .. tostring(err), vim.log.levels.WARN)
      cb(false)
      return
    end
    thread.resolved = resolved
    require('diffy.review.ui').decorate(session)
    cb(true)
  end)
end

local function raw_diff(root, extra_args, x, y, cb)
  local args = { 'diff', '-M' }
  vim.list_extend(args, extra_args)
  table.insert(args, x)
  table.insert(args, y)
  run.git(args, {
    cwd = root,
    notify_on_error = false,
    on_exit = function(res)
      cb(res.code == 0 and (res.stdout or '') or '')
    end,
  })
end

--- The raw text lines of one file's section of a multi-file unified diff
--- (from `diff --git a/X b/Y` up to, not including, the next such header),
--- matching `path` against either name - `model.diff_position`'s input.
local function slice_file_section(raw_text, path)
  local lines = vim.split(raw_text, '\n', { plain = true })
  local start_i
  for i, line in ipairs(lines) do
    local a, b = line:match('^diff %-%-git a/(.-) b/(.*)$')
    if a then
      if start_i then
        return vim.list_slice(lines, start_i, i - 1)
      end
      if a == path or b == path then
        start_i = i
      end
    end
  end
  if start_i then
    return vim.list_slice(lines, start_i, #lines)
  end
  return nil
end

--- The hunks for `path` in `files` (from `model.parse_diff_files`),
--- matching either side's name (a plain `old_path`-only lookup, as
--- `model.diff_file_hunks` does, isn't enough here: depending on which
--- side of the (X, Y) diff `path` names the file on, it may be either
--- end's name). `{}` if the file is unrelated to this diff (unchanged).
local function find_hunks(files, path)
  for _, f in ipairs(files) do
    if f.old_path == path or f.new_path == path then
      return f.hunks, f.old_path, f.new_path
    end
  end
  return {}, path, path
end

--- `:Diffy review push` (contract §9.4): recreate the viewer's one pending
--- review from local drafts (`state == 'draft'` comments - the source of
--- truth). Validates every draft against the `merge-base...C` diff, and
--- tracks old-side (`C^` -> merge-base) anchors, *before* any API call
--- (GitHub rejects the whole review on one bad thread) - a draft that
--- fails either check stays local with a warning; everything else is
--- pushed via `M.push_execute`. `cb(ok, warnings)`, `warnings` a string[].
function M.push(session, cb)
  local review = session.review
  if not (review and review.pr) then
    vim.notify('diffy: nothing to push - open :Diffy pr first', vim.log.levels.WARN)
    cb(false, {})
    return
  end
  local root = session.root
  local merge_base = review.merge_base
  local head_sha = session.head_sha

  -- A draft's thread needs full (re)creation - the primary/other-commit
  -- paths below - unless it has a surviving `published` comment: step 1
  -- deletes the pending review's own comments only (not published ones,
  -- fake_github.lua mirrors this at comment granularity), so a thread
  -- with nothing published left (a brand-new local draft, `t<N>` id, or a
  -- `:Diffy review pull`-imported one, real id but every comment still
  -- `draft`/`pending`) is gone once step 1 runs and must be recreated;
  -- one with a published root (a reply drafted onto an existing,
  -- surviving thread) keeps its id and just gets `addPullRequestReviewThreadReply`.
  -- Later drafts on a thread that has nothing published are replies to the
  -- thread this push creates (`followups`); its id is only known afterwards.
  local roots, replies, followups = {}, {}, {}
  for _, t in ipairs(review.threads) do
    local has_published = false
    for _, c in ipairs(t.comments) do
      if c.state == 'published' then
        has_published = true
      end
    end
    local root_draft
    for i, c in ipairs(t.comments) do
      if c.state == 'draft' then
        if i == 1 and not has_published then
          root_draft = { thread = t, comment = c }
          table.insert(roots, root_draft)
        elseif has_published then
          table.insert(replies, { thread = t, comment = c })
        elseif root_draft then
          table.insert(followups, { thread = t, comment = c, root = root_draft })
        end
      end
    end
  end
  if #roots == 0 and #replies == 0 then
    vim.notify('diffy: no drafts to push')
    cb(true, {})
    return
  end

  local warnings = {}
  local diff_cache = {}
  local function commit_diff(c, cb2)
    if diff_cache[c] then
      cb2(diff_cache[c])
      return
    end
    -- `-U0`, not `-U3`: `model.anchor_valid` itself adds the ±3 context
    -- window - it expects hunks bounded to exactly the changed lines
    -- (contract §9.4, `tests/test_review_tracking.lua`).
    raw_diff(root, { '-U0' }, merge_base, c, function(raw)
      local entry = { files = model.parse_diff_files(raw), raw = raw }
      diff_cache[c] = entry
      cb2(entry)
    end)
  end

  run.git({ 'diff', '-z', '-M', '--name-status', merge_base, head_sha }, {
    cwd = root,
    notify_on_error = false,
    on_exit = function(res)
      if session.closed then
        return
      end
      local rename_map = {}
      if res.code == 0 then
        for _, rec in ipairs(parse.name_status(res.stdout or '')) do
          if rec.status == 'R' then
            rename_map[rec.old_path] = rec.path
          end
        end
      end
      local function head_path(path)
        return rename_map[path] or path
      end

      local function after_validate()
        local new_side, old_side = {}, {}
        for _, d in ipairs(roots) do
          if d._invalid then
            table.insert(warnings, ('%s: %s'):format(d.thread.id, d._invalid))
          elseif d.thread.anchor.side == 'old' then
            table.insert(old_side, d)
          else
            new_side[d._commit] = new_side[d._commit] or {}
            table.insert(new_side[d._commit], d)
          end
        end
        local primary, best = head_sha, -1
        for c, list in pairs(new_side) do
          if #list > best then
            primary, best = c, #list
          end
        end
        local primary_threads = {}
        vim.list_extend(primary_threads, old_side)
        local other_drafts = {}
        for c, list in pairs(new_side) do
          if c == primary then
            vim.list_extend(primary_threads, list)
          else
            vim.list_extend(other_drafts, list)
          end
        end
        M.push_execute(session, {
          pr_id = review.pr.id,
          pending_review_id = review.pr.pending and review.pr.pending.id,
          primary_commit = primary,
          primary_threads = primary_threads,
          other_drafts = other_drafts,
          replies = replies,
          followups = followups,
          head_path = head_path,
          warnings = warnings,
        }, function(ok)
          cb(ok, warnings)
        end)
      end

      if #roots == 0 then
        after_validate()
        return
      end
      local remaining = #roots
      for _, d in ipairs(roots) do
        local anchor = d.thread.anchor
        local c = anchor.commit
        if anchor.side == 'old' then
          -- the full-PR view's left side is the merge-base itself (§3)
          c = anchor.commit == merge_base and head_sha or (anchor.commit:match('^(.+)%^$') or anchor.commit)
        end
        d._commit = c
        commit_diff(c, function(entry)
          local function done()
            remaining = remaining - 1
            if remaining == 0 then
              after_validate()
            end
          end
          if anchor.side == 'old' then
            raw_diff(root, { '-U0' }, anchor.commit, merge_base, function(traw)
              local tfiles = model.parse_diff_files(traw)
              local thunks, _, mb_name = find_hunks(tfiles, anchor.path)
              local mb_s, mb_e = model.map_range(thunks, anchor.start_line, anchor.end_line)
              if not mb_s then
                d._invalid = "old-side comment couldn't be tracked to the merge-base"
              else
                local vhunks = select(1, find_hunks(entry.files, mb_name))
                if model.anchor_valid(vhunks, 'old', mb_s, mb_e) then
                  d._line, d._end_line = mb_s, mb_e
                else
                  d._invalid = 'line could not be resolved'
                end
              end
              done()
            end)
          else
            local vhunks = select(1, find_hunks(entry.files, anchor.path))
            if model.anchor_valid(vhunks, 'new', anchor.start_line, anchor.end_line) then
              d._line, d._end_line = anchor.start_line, anchor.end_line
            else
              d._invalid = 'line could not be resolved'
            end
            done()
          end
        end)
      end
    end,
  })
end

--- Runs the mutations for a validated push (`M.push`'s second half, pulled
--- out to keep the classification code above readable): delete any
--- existing pending review, create the primary batch, single-line/
--- multi-line drafts on other commits (contract §9.4 steps 1-4), draft
--- replies (step 5), then drop every successfully-pushed draft comment
--- from `session.review.threads` (the very next `M.refresh` re-fetches its
--- authoritative, real-id form from GitHub - nothing is lost, and nothing
--- is left duplicated locally) and persist/reload. `cb(ok)`.
function M.push_execute(session, plan, cb)
  local review = session.review
  local root = session.root

  local function finish(ok)
    for _, group in ipairs({ plan.primary_threads, plan.other_drafts, plan.replies, plan.followups or {} }) do
      for _, d in ipairs(group) do
        if d._pushed then
          for i, c in ipairs(d.thread.comments) do
            if c == d.comment then
              table.remove(d.thread.comments, i)
              break
            end
          end
        end
      end
    end
    for i = #review.threads, 1, -1 do
      if #review.threads[i].comments == 0 then
        table.remove(review.threads, i)
      end
    end
    review.backend.save(session, review.branch, review.threads)
    M.refresh(session, function()
      if not session.closed then
        require('diffy.review.ui').decorate(session)
      end
      cb(ok)
    end)
  end

  local function push_replies(review_id)
    local i = 0
    local function next_reply()
      i = i + 1
      if i > #plan.replies then
        finish(true)
        return
      end
      local d = plan.replies[i]
      M.transport(MUTATIONS.add_reply, { r = review_id, t = d.reply_to or d.thread.id, b = d.comment.body }, function(data, err)
        if data then
          d._pushed = true
        else
          table.insert(plan.warnings, d.thread.id .. ': ' .. tostring(err))
        end
        next_reply()
      end)
    end
    next_reply()
  end

  -- Find the threads this push just created (matched by path and first body
  -- within the new pending review) so their follow-up drafts become replies.
  local function push_followups(review_id)
    local pending = {}
    for _, f in ipairs(plan.followups or {}) do
      if f.root._pushed then
        table.insert(pending, f)
      end
    end
    if #pending == 0 then
      push_replies(review_id)
      return
    end
    M.owner_repo(root, function(owner, name, err)
      if not owner then
        table.insert(plan.warnings, tostring(err))
        push_replies(review_id)
        return
      end
      paginate_threads(owner, name, session.range.pr_number, function(nodes)
        for _, f in ipairs(pending) do
          local path = plan.head_path(f.thread.anchor.path)
          for _, n in ipairs(nodes or {}) do
            local first = n.comments.nodes[1]
            if n.path == path and first and first.body == f.root.comment.body
              and first.pullRequestReview and first.pullRequestReview.id == review_id then
              f.reply_to = n.id
            end
          end
          if f.reply_to then
            table.insert(plan.replies, f)
          else
            table.insert(plan.warnings, f.thread.id .. ": couldn't find the pushed thread to reply to")
          end
        end
        push_replies(review_id)
      end)
    end)
  end

  local function push_other(review_id)
    local i = 0
    local function next_other()
      i = i + 1
      if i > #plan.other_drafts then
        push_followups(review_id)
        return
      end
      local d = plan.other_drafts[i]
      local anchor = d.thread.anchor
      if d._line == d._end_line then
        raw_diff(root, { '-U3' }, review.merge_base, d._commit, function(raw)
          local section = slice_file_section(raw, anchor.path)
          local pos = section and model.diff_position(section, d._line)
          if not pos then
            table.insert(plan.warnings, d.thread.id .. ": couldn't compute a diff position")
            next_other()
            return
          end
          M.transport(MUTATIONS.add_comment, {
            r = review_id,
            c = d._commit,
            p = plan.head_path(anchor.path),
            pos = pos,
            b = d.comment.body,
          }, function(data, err)
            if data then
              d._pushed = true
            else
              table.insert(plan.warnings, d.thread.id .. ': ' .. tostring(err))
            end
            next_other()
          end)
        end)
      else
        raw_diff(root, { '-U0' }, d._commit, session.head_sha, function(traw)
          local thunks = select(1, find_hunks(model.parse_diff_files(traw), anchor.path))
          local hs, he = model.map_range(thunks, d._line, d._end_line)
          if not hs then
            table.insert(plan.warnings, d.thread.id .. ": multi-line comment on another commit couldn't be tracked to HEAD")
            next_other()
            return
          end
          M.transport(MUTATIONS.add_thread, {
            r = review_id,
            p = plan.head_path(anchor.path),
            l = he,
            s = 'RIGHT',
            sl = hs ~= he and hs or nil,
            ss = hs ~= he and 'RIGHT' or nil,
            b = d.comment.body,
          }, function(data, err)
            if data then
              d._pushed = true
            else
              table.insert(plan.warnings, d.thread.id .. ': ' .. tostring(err))
            end
            next_other()
          end)
        end)
      end
    end
    next_other()
  end

  local function create_primary()
    local threads_input = {}
    for _, d in ipairs(plan.primary_threads) do
      local anchor = d.thread.anchor
      local input = {
        path = plan.head_path(anchor.path),
        body = d.comment.body,
        side = anchor.side == 'old' and 'LEFT' or 'RIGHT',
        line = d._end_line,
      }
      if d._line ~= d._end_line then
        input.startLine = d._line
        input.startSide = input.side
      end
      table.insert(threads_input, input)
    end
    M.transport(MUTATIONS.create_review, { pr = plan.pr_id, c = plan.primary_commit, t = threads_input }, function(data, err)
      if not data then
        vim.notify('diffy: push failed - ' .. tostring(err), vim.log.levels.ERROR)
        cb(false)
        return
      end
      for _, d in ipairs(plan.primary_threads) do
        d._pushed = true
      end
      push_other(data.addPullRequestReview.pullRequestReview.id)
    end)
  end

  if #plan.primary_threads + #plan.other_drafts + #plan.replies == 0 then
    finish(true)
    return
  end
  if plan.pending_review_id then
    M.transport(MUTATIONS.delete_review, { id = plan.pending_review_id }, function(_, err)
      if err then
        vim.notify('diffy: push failed - ' .. tostring(err), vim.log.levels.ERROR)
        cb(false)
        return
      end
      create_primary()
    end)
  else
    create_primary()
  end
end

--- `:Diffy review pull` (contract §9.4): imports the viewer's pending
--- review into local drafts, restoring each comment's anchor from
--- `originalCommit`/`originalLine` (not the live-tracked `commit`/`line` -
--- the whole point is a faithful re-push after a future step-1 delete, not
--- the nicest current display, which the normal read side already shows
--- regardless of pulling). Asks (contract, `prompt.lua`) before replacing
--- existing local drafts. `cb(ok)`.
function M.pull(session, cb)
  local review = session.review
  local pending = review and review.pr and review.pr.pending
  if not pending then
    vim.notify('diffy: no pending review to pull', vim.log.levels.WARN)
    cb(false)
    return
  end

  local imported, by_thread = {}, {}
  for _, t in ipairs(review.threads) do
    for _, c in ipairs(t._raw_comments or {}) do
      if c.pullRequestReview and c.pullRequestReview.id == pending.id then
        local entry = by_thread[t.id]
        if not entry then
          entry = {
            id = t.id,
            backend = 'github',
            anchor = {
              path = t.anchor.path,
              side = t.anchor.side,
              start_line = c.originalStartLine or c.originalLine,
              end_line = c.originalLine,
              commit = c.originalCommit and c.originalCommit.oid,
              excerpt = nil,
            },
            comments = {},
            resolved = t.resolved,
          }
          by_thread[t.id] = entry
          table.insert(imported, entry)
        end
        table.insert(entry.comments, {
          id = c.id,
          author = c.author and c.author.login or 'unknown',
          body = c.body,
          created_at = c.createdAt,
          state = 'draft',
        })
      end
    end
  end
  if #imported == 0 then
    vim.notify('diffy: the pending review has nothing importable', vim.log.levels.WARN)
    cb(false)
    return
  end

  local function apply()
    local by_id = {}
    for _, t in ipairs(review.threads) do
      by_id[t.id] = t
    end
    for _, it in ipairs(imported) do
      local live = by_id[it.id]
      if live then
        live.anchor = it.anchor
        local have = {}
        for _, c in ipairs(live.comments) do
          have[c.id] = c
        end
        for _, c in ipairs(it.comments) do
          local existing = have[c.id]
          if existing then
            existing.state, existing.body = 'draft', c.body
          else
            table.insert(live.comments, c)
          end
        end
      end
    end
    review.backend.save(session, review.branch, review.threads)
    require('diffy.review.ui').decorate(session)
    vim.notify(('diffy: pulled %d thread(s) into local drafts'):format(#imported))
    cb(true)
  end

  if #M.load(session, M.branch(session)) > 0 then
    prompt.confirm(session, {
      'Local drafts already exist for this PR and may differ from the',
      'pending review on GitHub. Replace them?',
    }, function(accepted)
      if accepted then
        apply()
      else
        cb(false)
      end
    end)
  else
    apply()
  end
end

--- `:Diffy review submit [comment|approve|request_changes]` (contract
--- §9.4): push, then `submitPullRequestReview` with `event`/`body`
--- (composed in a float by the caller, `init.lua`). A normal `M.refresh`
--- (already run at the end of `M.push`) reloads everything fresh -
--- submitted comments simply stop being part of any pending review, so
--- they come back `published` on their own, no separate bookkeeping
--- needed. `cb(ok, warnings)`.
function M.submit(session, event, body, cb)
  M.push(session, function(ok, warnings)
    if not ok then
      cb(false, warnings)
      return
    end
    local review = session.review
    local pending = review.pr and review.pr.pending
    if not pending then
      vim.notify('diffy: nothing to submit - no pending review', vim.log.levels.WARN)
      cb(false, warnings)
      return
    end
    M.transport(MUTATIONS.submit, { r = pending.id, e = event, b = body }, function(data, err)
      if not data then
        vim.notify('diffy: submit failed - ' .. tostring(err), vim.log.levels.ERROR)
        cb(false, warnings)
        return
      end
      M.refresh(session, function()
        if not session.closed then
          require('diffy.review.ui').decorate(session)
        end
        cb(true, warnings)
      end)
    end)
  end)
end

return M

-- Local review backend: comments meant to be fed to an LLM. Available in
-- `:Diffy` and `:Diffy branch`. State lives in
-- `.git/diffy/<branch>/local.json`; `:Diffy review export` renders
-- `.git/diffy/<branch>/review.md`.
local store = require('diffy.review.store')
local model = require('diffy.review.model')
local run = require('diffy.git.run')
local repo = require('diffy.git.repo')

local M = {}

M.name = 'local'
-- Suggestion blocks are a GitHub-only feature.
M.capabilities = { resolve = true, suggestions = false }

--- Current branch name, read from `<gitdir>/HEAD` without a subprocess
--- (`session.gitdir` already resolves worktrees whose `.git` is a file).
--- Falls back to a short HEAD sha (detached) or `'detached'`.
function M.branch(session)
  local head_path = session.gitdir .. '/HEAD'
  if vim.fn.filereadable(head_path) == 1 then
    local content = vim.fn.readfile(head_path)[1] or ''
    local name = content:match('^ref: refs/heads/(.+)$')
    if name then
      return name
    end
  end
  return (session.head_sha and session.head_sha:sub(1, 7)) or 'detached'
end

local cached_author
--- `git config user.name`, cached for the process lifetime. Synchronous,
--- but only runs the first time the user writes a comment.
function M.author(root)
  if cached_author then
    return cached_author
  end
  local res = vim.system({ 'git', 'config', 'user.name' }, { cwd = root, text = true }):wait()
  local name = res.code == 0 and vim.trim(res.stdout or '') or ''
  cached_author = name ~= '' and name or (vim.env.USER or 'unknown')
  return cached_author
end

local function local_json_path(session, branch)
  return store.dir(session.gitdir, branch) .. '/local.json'
end

local function review_md_path(session, branch)
  return store.dir(session.gitdir, branch) .. '/review.md'
end

--- Persisted threads for `branch`, or `{}` if there is no state yet.
function M.load(session, branch)
  local data = store.load(local_json_path(session, branch))
  if not data or not data.threads then
    return {}
  end
  local out = {}
  for _, t in ipairs(data.threads) do
    t.comments = t.comments or {}
    table.insert(out, t)
  end
  return out
end

function M.save(session, branch, threads)
  store.save(local_json_path(session, branch), { threads = threads })
end

function M.clear(session, branch)
  store.delete(local_json_path(session, branch))
end

--- A thread only shows in the exact view it was written in (no
--- cross-commit tracking). Re-locates the excerpt against that view's
--- current lines, updating `thread.anchor` in place on success (persisted
--- on the next `save`); marks the thread `_detached` (session-only) on
--- failure.
function M.place(session, thread)
  local side = model.pair_side(session.pair, session.head_sha, thread.anchor)
  local win = side and session.wins[side]
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  if not model.relocate(thread.anchor, lines) then
    thread._detached = true
    return nil
  end
  return { win = side, start_line = thread.anchor.start_line, end_line = thread.anchor.end_line }
end

-- ---------------------------------------------------------------------
-- export

--- Current buffer lines for `commit`/`path` if a loaded buffer already has
--- them (a live worktree edit), else read from disk (`worktree`) or a git
--- blob (`index`/a sha). `cb(lines|nil)`.
local function read_side(session, commit, path, cb)
  if commit == 'worktree' then
    local abspath = session.root .. '/' .. path
    local buf = vim.fn.bufnr(abspath)
    if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
      cb(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      return
    end
    if vim.fn.filereadable(abspath) == 1 then
      cb(vim.fn.readfile(abspath))
    else
      cb(nil)
    end
    return
  end
  local object = commit == 'index' and (':0:' .. path) or (commit .. ':' .. path)
  run.git({ 'show', object }, {
    cwd = session.root,
    session = session,
    notify_on_error = false,
    on_exit = function(res)
      if res.code ~= 0 then
        cb(nil)
        return
      end
      cb(vim.split(res.stdout or '', '\n', { plain = true }))
    end,
  })
end

--- The (left, right) rev pair whose diff produced the comment: the view it
--- was written in (`thread.view`), or for drafts saved before that was
--- recorded, a guess from the anchor's commit and side.
local function hunk_pair(thread)
  if thread.view then
    return thread.view.left, thread.view.right
  end
  local commit, side = thread.anchor.commit, thread.anchor.side
  if commit == 'worktree' then
    return 'INDEX', 'WORKTREE'
  elseif commit == 'index' then
    return side == 'old' and 'INDEX' or 'HEAD', side == 'old' and 'WORKTREE' or 'INDEX'
  end
  return commit .. '^', commit
end

local function short_commit(commit)
  if commit == 'worktree' or commit == 'index' then
    return commit
  end
  return commit:sub(1, 7)
end

--- 3 lines of context around `[start_line, end_line]` in `lines`, numbered.
--- Returns an array of lines (`writefile` mangles embedded `\n` within a
--- single list entry into NUL bytes rather than real line breaks).
local function numbered_excerpt(lines, start_line, end_line)
  local lo = math.max(1, start_line - 3)
  local hi = math.min(#lines, end_line + 3)
  local out = {}
  for l = lo, hi do
    table.insert(out, ('%d  %s'):format(l, lines[l] or ''))
  end
  return out
end

local function fence_lang(path)
  local ft = vim.filetype.match({ filename = path })
  return ft or ''
end

--- Join independently-async `jobs` (`fun(done: fun())[]`), calling `done()`
--- once every job has called its own `done`.
local function join(jobs, done)
  if #jobs == 0 then
    done()
    return
  end
  local remaining = #jobs
  for _, job in ipairs(jobs) do
    job(function()
      remaining = remaining - 1
      if remaining == 0 then
        done()
      end
    end)
  end
end

--- `:Diffy review export`: render `review.md` for every non-`sent` comment,
--- mark them `sent`, save, and copy the prompt to `+`. `cb(ok, path_or_err)`.
function M.export(session, cb)
  local review = session.review
  local pending = {}
  for _, thread in ipairs(review.threads) do
    for _, comment in ipairs(thread.comments) do
      if comment.state ~= 'sent' then
        table.insert(pending, { thread = thread, comment = comment })
      end
    end
  end
  if #pending == 0 then
    cb(false, 'nothing to export')
    return
  end

  local sides, diffs = {}, {}
  for _, item in ipairs(pending) do
    local a = item.thread.anchor
    sides[a.commit .. '\0' .. a.path] = { commit = a.commit, path = a.path }
    local left, right = hunk_pair(item.thread)
    diffs[left .. '\0' .. right .. '\0' .. a.path] = { left = left, right = right, path = a.path }
  end

  local side_lines, diff_hunks = {}, {}
  local jobs = {}
  for key, s in pairs(sides) do
    table.insert(jobs, function(done)
      read_side(session, s.commit, s.path, function(lines)
        side_lines[key] = lines or {}
        done()
      end)
    end)
  end
  for key, d in pairs(diffs) do
    table.insert(jobs, function(done)
      local args = { 'diff', '-U3' }
      vim.list_extend(args, repo.diff_args(d.left, d.right))
      vim.list_extend(args, { '--', d.path })
      run.git(args, {
        cwd = session.root,
        session = session,
        notify_on_error = false,
        on_exit = function(res)
          diff_hunks[key] = model.parse_hunks(res.code == 0 and res.stdout or '')
          done()
        end,
      })
    end)
  end

  join(jobs, function()
    table.sort(pending, function(a, b)
      if a.thread.anchor.path ~= b.thread.anchor.path then
        return a.thread.anchor.path < b.thread.anchor.path
      end
      return a.thread.anchor.start_line < b.thread.anchor.start_line
    end)

    local out = {}
    for _, item in ipairs(pending) do
      local thread, comment = item.thread, item.comment
      local a = thread.anchor
      local key = a.commit .. '\0' .. a.path
      local lines = side_lines[key] or {}
      model.relocate(a, lines)

      local range = a.start_line == a.end_line and tostring(a.start_line)
        or ('%d-%d'):format(a.start_line, a.end_line)
      local side_label = a.side == 'old' and 'old side' or 'new side'
      table.insert(
        out,
        ('## %s \226\128\148 %s:%s (%s) \194\183 commit %s'):format(comment.id, a.path, range, side_label, short_commit(a.commit))
      )
      table.insert(out, '```' .. fence_lang(a.path))
      vim.list_extend(out, numbered_excerpt(lines, a.start_line, a.end_line))
      table.insert(out, '```')

      local left, right = hunk_pair(item.thread)
      local hunks = diff_hunks[left .. '\0' .. right .. '\0' .. a.path] or {}
      local hunk = model.find_hunk(hunks, a.side, a.start_line, a.end_line)
      table.insert(out, '<details><summary>diff hunk</summary>')
      table.insert(out, '')
      table.insert(out, '```diff')
      if hunk then
        vim.list_extend(out, hunk.lines)
      else
        -- no changed hunk covers this anchor (a comment on unchanged
        -- context): synthesize a context-only pseudo-hunk from the excerpt.
        table.insert(
          out,
          ('@@ -%d,%d +%d,%d @@'):format(a.start_line, #lines > 0 and (a.end_line - a.start_line + 1) or 0, a.start_line, a.end_line - a.start_line + 1)
        )
        for l = a.start_line, a.end_line do
          table.insert(out, ' ' .. (lines[l] or ''))
        end
      end
      table.insert(out, '```')
      table.insert(out, '</details>')
      table.insert(out, '')
      vim.list_extend(out, vim.split(comment.body, '\n', { plain = true }))
      table.insert(out, '')
    end

    local function finish(base_sha, base_ref)
      local branch = review.branch
      local base_line
      if base_sha then
        base_line = ('base: %s (%s)'):format(base_sha:sub(1, 7), base_ref)
      else
        base_line = 'base: (no upstream)'
      end
      local head_sha = session.head_sha or '?'
      local function rev_label(rev)
        return short_commit(model.rev_to_commit(rev, head_sha))
      end
      local range_desc = ('%s..%s'):format(rev_label(session.pair.left), rev_label(session.pair.right))
      local header = {
        '# Review of ' .. branch,
        ('%s \194\183 head: %s \194\183 range: %s'):format(base_line, head_sha:sub(1, 7), range_desc),
        '',
      }
      vim.list_extend(header, out)
      local path = review_md_path(session, branch)
      vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
      vim.fn.writefile(header, path)

      for _, item in ipairs(pending) do
        item.comment.state = 'sent'
      end
      M.save(session, branch, review.threads)

      vim.fn.setreg('+', require('diffy').config.review_prompt:format(path))
      cb(true, path)
    end

    run.git({ 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}' }, {
      cwd = session.root,
      session = session,
      notify_on_error = false,
      on_exit = function(res)
        if res.code ~= 0 then
          finish(nil, nil)
          return
        end
        local upstream = vim.trim(res.stdout or '')
        run.git({ 'merge-base', upstream, 'HEAD' }, {
          cwd = session.root,
          session = session,
          notify_on_error = false,
          on_exit = function(res2)
            if res2.code ~= 0 then
              finish(nil, nil)
            else
              finish(vim.trim(res2.stdout or ''), upstream)
            end
          end,
        })
      end,
    })
  end)
end

return M

-- Repository-level helpers: locating the root, merge-base and branch-base
-- resolution (§4), cleanliness checks (§3/§4/§7), and translating a
-- (left, right) rev pair into `git diff` arguments (§3's Unstaged/Staged
-- collapse to plain worktree/--cached diffs).
--
-- Every function below takes an optional trailing `session`: when given, it
-- is forwarded to `git/run.lua`'s `M.run`/`M.git`, which no-ops the whole
-- callback (this module's own `on_exit` included) once that session is torn
-- down. Callers with no live session yet (`checkout.lua`'s `M.restore`,
-- which works with no diffy session open at all) simply omit it.
local run = require('diffy.git.run')
local parse = require('diffy.git.parse')

local M = {}

--- `git rev-parse --show-toplevel` for `cwd`. `on_exit(root, err)`.
function M.root(cwd, on_exit, session)
  run.git({ 'rev-parse', '--show-toplevel' }, {
    cwd = cwd,
    session = session,
    notify_on_error = false,
    on_exit = function(res)
      if res.code ~= 0 then
        on_exit(nil, vim.trim(res.stderr or ''))
      else
        on_exit(vim.trim(res.stdout or ''), nil)
      end
    end,
  })
end

--- Current `HEAD` sha, or `nil` on an unborn branch. `on_exit(sha, err)`.
function M.head_sha(root, on_exit, session)
  run.git({ 'rev-parse', 'HEAD' }, {
    cwd = root,
    session = session,
    notify_on_error = false,
    on_exit = function(res)
      if res.code ~= 0 then
        on_exit(nil, vim.trim(res.stderr or ''))
      else
        on_exit(vim.trim(res.stdout or ''), nil)
      end
    end,
  })
end

--- `git merge-base a b`. `on_exit(sha, err)`.
function M.merge_base(root, a, b, on_exit, session)
  run.git({ 'merge-base', a, b }, {
    cwd = root,
    session = session,
    notify_on_error = false,
    on_exit = function(res)
      if res.code ~= 0 then
        on_exit(nil, vim.trim(res.stderr or ''))
      else
        on_exit(vim.trim(res.stdout or ''), nil)
      end
    end,
  })
end

--- §4 `branch` base resolution: explicit arg, else the PR base of the
--- current branch (`gh pr view`), else `origin`'s default branch
--- (`gh repo view`). `on_exit(ref, err)`.
function M.resolve_base(root, explicit, on_exit, session)
  if explicit and explicit ~= '' then
    on_exit(explicit, nil)
    return
  end
  run.run({ 'gh', 'pr', 'view', '--json', 'baseRefName', '-q', '.baseRefName' }, {
    cwd = root,
    session = session,
    notify_on_error = false,
    on_exit = function(res)
      local base = vim.trim(res.stdout or '')
      if res.code == 0 and base ~= '' then
        on_exit(base, nil)
        return
      end
      run.run({ 'gh', 'repo', 'view', '--json', 'defaultBranchRef', '-q', '.defaultBranchRef.name' }, {
        cwd = root,
        session = session,
        notify_on_error = false,
        on_exit = function(res2)
          local default_branch = vim.trim(res2.stdout or '')
          if res2.code == 0 and default_branch ~= '' then
            on_exit(default_branch, nil)
          else
            on_exit(nil, 'diffy: could not resolve branch base (' .. vim.trim(res2.stderr or '') .. ')')
          end
        end,
      })
    end,
  })
end

--- Parsed `git status --porcelain=v2 -z --untracked-files=all` entries for
--- the whole repo (untracked tree entries, per-file cleanliness lookups).
--- `--untracked-files=all` is load-bearing for §5: without it, git reports a
--- brand-new untracked directory as a single `?? dir/` entry instead of its
--- files individually, so the tree can't group them like any other
--- directory. `on_exit(entries, err)`.
function M.status(root, on_exit, session)
  run.git({ 'status', '--porcelain=v2', '-z', '--untracked-files=all' }, {
    cwd = root,
    session = session,
    notify_on_error = false,
    on_exit = function(res)
      if res.code ~= 0 then
        on_exit(nil, vim.trim(res.stderr or ''))
      else
        on_exit(parse.status_v2(res.stdout or ''), nil)
      end
    end,
  })
end

--- Whether `root`'s tree has no staged/unstaged changes to tracked files
--- (untracked/ignored files don't count). `path`, if given, restricts the
--- check to that pathspec (§3 real-file rule: "the file has no uncommitted
--- changes"). `on_exit(clean, err)`.
function M.is_clean(root, path, on_exit, session)
  local args = { 'status', '--porcelain=v2', '-z' }
  if path then
    vim.list_extend(args, { '--', path })
  end
  run.git(args, {
    cwd = root,
    session = session,
    notify_on_error = false,
    on_exit = function(res)
      if res.code ~= 0 then
        on_exit(nil, vim.trim(res.stderr or ''))
        return
      end
      local dirty = false
      for _, e in ipairs(parse.status_v2(res.stdout or '')) do
        if e.kind ~= 'untracked' and e.kind ~= 'ignored' then
          dirty = true
          break
        end
      end
      on_exit(not dirty, nil)
    end,
  })
end

--- Default commit range for bare `:Diffy` (§4): `@{u}..HEAD` if the current
--- branch has an upstream, else the last 20 commits. `on_exit(spec)` where
--- `spec` is `{ expr = 'A..B' }` or `{ n = 20 }` (passed to `git log` as a
--- rev range or a `-n` limit respectively).
function M.default_range(root, on_exit, session)
  run.git({ 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}' }, {
    cwd = root,
    session = session,
    notify_on_error = false,
    on_exit = function(res)
      if res.code == 0 then
        on_exit({ expr = '@{u}..HEAD' })
      else
        on_exit({ n = 20 })
      end
    end,
  })
end

--- Args to append to `git diff [flags]` for the pair `(left, right)`, where
--- each is `'INDEX'`, `'WORKTREE'`, `'HEAD'`, or a commit sha (§3's
--- Unstaged/Staged rows collapse to a plain/`--cached` diff with no
--- explicit revs, matching git's own defaults for "worktree" and "index").
function M.diff_args(left, right)
  if right == 'WORKTREE' then
    if left == 'INDEX' then
      return {}
    end
    return { left }
  elseif right == 'INDEX' then
    if left == 'HEAD' then
      return { '--cached' }
    end
    return { '--cached', left }
  else
    return { left, right }
  end
end

return M

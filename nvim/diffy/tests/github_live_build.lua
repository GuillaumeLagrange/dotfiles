-- `make test-gh` step 1: build the standard history fixture and push it to
-- a fresh base/head branch pair on the real sandbox repo, checking out the
-- head branch locally *as that same remote name* (`:Diffy pr`'s `find_pr`
-- matches by the current branch name against the PR's `headRefName`). Env
-- (from `github_live.sh`): DIFFY_TESTGH_WORK, DIFFY_TESTGH_BASE,
-- DIFFY_TESTGH_HEAD, DIFFY_TESTGH_REPO.
local ok, err = pcall(function()
  local Repo = require('tests.helpers.repo')
  local work = vim.env.DIFFY_TESTGH_WORK
  local base = vim.env.DIFFY_TESTGH_BASE
  local head = vim.env.DIFFY_TESTGH_HEAD
  local repo_slug = vim.env.DIFFY_TESTGH_REPO

  local r = Repo.standard() -- ends on branch 'feat', based on 'main'

  local function git(args)
    local res = vim.system(vim.list_extend({ 'git' }, args), { cwd = r.dir, text = true }):wait()
    if res.code ~= 0 then
      error(('git %s failed: %s'):format(table.concat(args, ' '), res.stderr or ''))
    end
    return vim.trim(res.stdout or '')
  end

  git({ 'remote', 'add', 'origin', ('https://github.com/%s.git'):format(repo_slug) })
  git({ 'push', '-q', 'origin', 'main:' .. base, 'feat:' .. head })
  git({ 'branch', base, 'main' }) -- local alias: `repo.merge_base` resolves the PR's baseRefName locally
  git({ 'checkout', '-q', '-b', head, 'feat' })

  vim.fn.mkdir(work, 'p')
  vim.fn.system({ 'cp', '-r', r.dir, work .. '/repo' })
end)

if not ok then
  io.stderr:write('diffy: test-gh build failed: ' .. tostring(err) .. '\n')
  os.exit(1)
end
os.exit(0)

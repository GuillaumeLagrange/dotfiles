-- Async vim.system wrapper for git/gh calls. The UI never blocks on a
-- subprocess (contract §1); every caller passes `opts.cwd` (the repo root)
-- and gets its result via `opts.on_exit`, scheduled onto the main loop.
local M = {}

--- Run `git <args>` asynchronously.
--- @param args string[] arguments after `git`
--- @param opts { cwd: string, on_exit?: fun(res: vim.SystemCompleted), notify_on_error?: boolean }
--- @return vim.SystemObj
function M.git(args, opts)
  opts = opts or {}
  return M.run({ 'git', unpack(args) }, opts)
end

--- Run an arbitrary command asynchronously (`gh` calls use this directly).
--- On a nonzero exit, surfaces the failure via `vim.notify` unless
--- `opts.notify_on_error == false`.
--- @param cmd string[]
--- @param opts { cwd: string, on_exit?: fun(res: vim.SystemCompleted), notify_on_error?: boolean }
--- @return vim.SystemObj
function M.run(cmd, opts)
  opts = opts or {}
  return vim.system(cmd, { cwd = opts.cwd, text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 and opts.notify_on_error ~= false then
        vim.notify(
          ('diffy: `%s` failed (%d)\n%s'):format(table.concat(cmd, ' '), res.code, vim.trim(res.stderr or '')),
          vim.log.levels.ERROR
        )
      end
      if opts.on_exit then
        opts.on_exit(res)
      end
    end)
  end)
end

--- Fire `User DiffyReady` once a view (or refresh) has finished rendering.
--- Tests wait on this instead of sleeping. Scheduled so it always runs after
--- any in-flight work from the same event-loop tick.
--- @param data table|nil forwarded as the autocmd's `data`
function M.ready(data)
  vim.schedule(function()
    vim.api.nvim_exec_autocmds('User', { pattern = 'DiffyReady', modeline = false, data = data })
  end)
end

return M

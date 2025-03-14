vim.cmd('cnoreabbrev octo Octo')

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'octo',
  callback = function()
    vim.keymap.set('i', '@', '@<C-x><C-o>', { silent = true, buffer = true })
    vim.keymap.set('i', '#', '#<C-x><C-o>', { silent = true, buffer = true })
  end,
})

return {
  'pwntester/octo.nvim',
  dev = true,
  dependencies = {
    'nvim-lua/plenary.nvim',
    'nvim-telescope/telescope.nvim',
    'nvim-tree/nvim-web-devicons',
  },
  keys = {
    '<leader>op',
    '<leader>ov',
  },
  cmd = { 'Octo' },
  opts = function()
    vim.keymap.set('n', '<leader>op', function()
      require('utils').close_octo_buffers()
      vim.api.nvim_command('Octo pr')
    end, { desc = 'Open PR for current branch' })
    vim.keymap.set('n', '<leader>ov', '<cmd>Octo review<CR>', { desc = 'Start or resume review' })
    vim.keymap.set('n', '<leader>ot', '<cmd>Octo review thread<CR>', { desc = 'Show review threads' })
    vim.keymap.set('n', '<leader>or', '<cmd>Octo thread resolve<CR>', { desc = 'Resolve thread' })

    return {
      picker = 'telescope',
      use_local_fs = true,
      enable_builtin = true,
      reviews = {
        auto_show_threads = false,
        focus = 'right',
      },
      suppress_missing_scope = {
        projects_v2 = true,
      },
      default_to_projects_v2 = true,
      mappings_disable_default = true,
      mappings = {
        issue = {
          close_issue = { lhs = '<space>ic', desc = 'close issue' },
          reopen_issue = { lhs = '<space>io', desc = 'reopen issue' },
          list_issues = { lhs = '<space>il', desc = 'list open issues on same repo' },
          reload = { lhs = '<C-r>', desc = 'reload issue' },
          open_in_browser = { lhs = '<C-b>', desc = 'open issue in browser' },
          copy_url = { lhs = '<C-y>', desc = 'copy url to system clipboard' },
          add_assignee = { lhs = '<space>aa', desc = 'add assignee' },
          remove_assignee = { lhs = '<space>ad', desc = 'remove assignee' },
          create_label = { lhs = '<space>lc', desc = 'create label' },
          add_label = { lhs = '<space>la', desc = 'add label' },
          remove_label = { lhs = '<space>ld', desc = 'remove label' },
          goto_issue = { lhs = '<space>gi', desc = 'navigate to a local repo issue' },
          add_comment = { lhs = '<space>oca', desc = 'add comment' },
          delete_comment = { lhs = '<space>ocd', desc = 'delete comment' },
          next_comment = { lhs = ']c', desc = 'go to next comment' },
          prev_comment = { lhs = '[c', desc = 'go to previous comment' },
          react_hooray = { lhs = '<space>rp', desc = 'add/remove 🎉 reaction' },
          react_heart = { lhs = '<space>rh', desc = 'add/remove ❤️ reaction' },
          react_eyes = { lhs = '<space>re', desc = 'add/remove 👀 reaction' },
          react_thumbs_up = { lhs = '<space>r+', desc = 'add/remove 👍 reaction' },
          react_thumbs_down = { lhs = '<space>r-', desc = 'add/remove 👎 reaction' },
          react_rocket = { lhs = '<space>rr', desc = 'add/remove 🚀 reaction' },
          react_laugh = { lhs = '<space>rl', desc = 'add/remove 😄 reaction' },
          react_confused = { lhs = '<space>rc', desc = 'add/remove 😕 reaction' },
        },
        pull_request = {
          checkout_pr = { lhs = '<space>po', desc = 'checkout PR' },
          merge_pr = { lhs = '<space>pm', desc = 'merge commit PR' },
          squash_and_merge_pr = { lhs = '<space>psm', desc = 'squash and merge PR' },
          rebase_and_merge_pr = { lhs = '<space>prm', desc = 'rebase and merge PR' },
          list_commits = { lhs = '<space>pc', desc = 'list PR commits' },
          list_changed_files = { lhs = '<space>pf', desc = 'list PR changed files' },
          show_pr_diff = { lhs = '<space>pd', desc = 'show PR diff' },
          add_reviewer = { lhs = '<space>va', desc = 'add reviewer' },
          remove_reviewer = { lhs = '<space>vd', desc = 'remove reviewer request' },
          close_issue = { lhs = '<space>ic', desc = 'close PR' },
          reopen_issue = { lhs = '<space>io', desc = 'reopen PR' },
          list_issues = { lhs = '<space>il', desc = 'list open issues on same repo' },
          reload = { lhs = '<C-r>', desc = 'reload PR' },
          open_in_browser = { lhs = '<C-b>', desc = 'open PR in browser' },
          copy_url = { lhs = '<leader>oy', desc = 'copy url to system clipboard' },
          goto_file = { lhs = 'gf', desc = 'go to file' },
          add_assignee = { lhs = '<space>aa', desc = 'add assignee' },
          remove_assignee = { lhs = '<space>ad', desc = 'remove assignee' },
          create_label = { lhs = '<space>lc', desc = 'create label' },
          add_label = { lhs = '<space>la', desc = 'add label' },
          remove_label = { lhs = '<space>ld', desc = 'remove label' },
          goto_issue = { lhs = '<space>gi', desc = 'navigate to a local repo issue' },
          add_comment = { lhs = '<space>oca', desc = 'add comment' },
          delete_comment = { lhs = '<space>ocd', desc = 'delete comment' },
          next_comment = { lhs = ']c', desc = 'go to next comment' },
          prev_comment = { lhs = '[c', desc = 'go to previous comment' },
          react_hooray = { lhs = '<space>rp', desc = 'add/remove 🎉 reaction' },
          react_heart = { lhs = '<space>rh', desc = 'add/remove ❤️ reaction' },
          react_eyes = { lhs = '<space>re', desc = 'add/remove 👀 reaction' },
          react_thumbs_up = { lhs = '<space>r+', desc = 'add/remove 👍 reaction' },
          react_thumbs_down = { lhs = '<space>r-', desc = 'add/remove 👎 reaction' },
          react_rocket = { lhs = '<space>rr', desc = 'add/remove 🚀 reaction' },
          react_laugh = { lhs = '<space>rl', desc = 'add/remove 😄 reaction' },
          react_confused = { lhs = '<space>rc', desc = 'add/remove 😕 reaction' },
          review_start = { lhs = '<space>vs', desc = 'start a review for the current PR' },
          review_resume = { lhs = '<space>vr', desc = 'resume a pending review for the current PR' },
        },
        review_thread = {
          goto_issue = { lhs = '<space>gi', desc = 'navigate to a local repo issue' },
          add_comment = { lhs = '<space>oca', desc = 'add comment' },
          add_suggestion = { lhs = '<space>osa', desc = 'add suggestion' },
          delete_comment = { lhs = '<space>ocd', desc = 'delete comment' },
          next_comment = { lhs = ']c', desc = 'go to next comment' },
          prev_comment = { lhs = '[c', desc = 'go to previous comment' },
          select_next_entry = { lhs = ']q', desc = 'move to next changed file' },
          select_prev_entry = { lhs = '[q', desc = 'move to previous changed file' },
          select_first_entry = { lhs = '[Q', desc = 'move to first changed file' },
          select_last_entry = { lhs = ']Q', desc = 'move to last changed file' },
          close_review_tab = { lhs = '<C-c>', desc = 'close review tab' },
          react_hooray = { lhs = '<space>rp', desc = 'add/remove 🎉 reaction' },
          react_heart = { lhs = '<space>rh', desc = 'add/remove ❤️ reaction' },
          react_eyes = { lhs = '<space>re', desc = 'add/remove 👀 reaction' },
          react_thumbs_up = { lhs = '<space>r+', desc = 'add/remove 👍 reaction' },
          react_thumbs_down = { lhs = '<space>r-', desc = 'add/remove 👎 reaction' },
          react_rocket = { lhs = '<space>rr', desc = 'add/remove 🚀 reaction' },
          react_laugh = { lhs = '<space>rl', desc = 'add/remove 😄 reaction' },
          react_confused = { lhs = '<space>rc', desc = 'add/remove 😕 reaction' },
        },
        submit_win = {
          approve_review = { lhs = '<C-a>', desc = 'approve review' },
          comment_review = { lhs = '<C-m>', desc = 'comment review' },
          request_changes = { lhs = '<C-r>', desc = 'request changes review' },
          close_review_tab = { lhs = '<C-c>', desc = 'close review tab' },
        },
        review_diff = {
          submit_review = { lhs = '<leader>ovs', desc = 'submit review' },
          discard_review = { lhs = '<leader>ovd', desc = 'discard review' },
          add_review_comment = { lhs = '<space>oca', desc = 'add a new review comment', mode = { 'n', 'x' } },
          add_review_suggestion = { lhs = '<space>osa', desc = 'add a new review suggestion', mode = { 'n', 'x' } },
          focus_files = { lhs = '<leader>oe', desc = 'move focus to changed file panel' },
          toggle_files = { lhs = '<leader>ob', desc = 'hide/show changed files panel' },
          next_thread = { lhs = ']t', desc = 'move to next thread' },
          prev_thread = { lhs = '[t', desc = 'move to previous thread' },
          select_next_entry = { lhs = ']q', desc = 'move to next changed file' },
          select_prev_entry = { lhs = '[q', desc = 'move to previous changed file' },
          select_first_entry = { lhs = '[Q', desc = 'move to first changed file' },
          select_last_entry = { lhs = ']Q', desc = 'move to last changed file' },
          close_review_tab = { lhs = '<C-c>', desc = 'close review tab' },
          toggle_viewed = { lhs = '<leader><space>', desc = 'toggle viewer viewed state' },
          goto_file = { lhs = 'gf', desc = 'go to file' },
        },
        file_panel = {
          submit_review = { lhs = '<leader>ovs', desc = 'submit review' },
          discard_review = { lhs = '<leader>ovd', desc = 'discard review' },
          next_entry = { lhs = 'j', desc = 'move to next changed file' },
          prev_entry = { lhs = 'k', desc = 'move to previous changed file' },
          select_entry = { lhs = '<cr>', desc = 'show selected changed file diffs' },
          refresh_files = { lhs = 'R', desc = 'refresh changed files panel' },
          focus_files = { lhs = '<leader>e', desc = 'move focus to changed file panel' },
          toggle_files = { lhs = '<leader>b', desc = 'hide/show changed files panel' },
          select_next_entry = { lhs = ']q', desc = 'move to next changed file' },
          select_prev_entry = { lhs = '[q', desc = 'move to previous changed file' },
          select_first_entry = { lhs = '[Q', desc = 'move to first changed file' },
          select_last_entry = { lhs = ']Q', desc = 'move to last changed file' },
          close_review_tab = { lhs = '<C-c>', desc = 'close review tab' },
          toggle_viewed = { lhs = '<leader><space>', desc = 'toggle viewer viewed state' },
        },
        repo = {},
      },

      ui = {
        use_signcolumn = true,
      },
    }
  end,
}

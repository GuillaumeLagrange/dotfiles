return {
  'saghen/blink.cmp',
  version = '1.*',
  event = { 'InsertEnter', 'CmdlineEnter' },
  dependencies = {
    'L3MON4D3/LuaSnip',
    'rafamadriz/friendly-snippets',
  },

  ---@module 'blink.cmp'
  ---@type blink.cmp.Config
  opts = {
    keymap = {
      preset = 'default',
      -- Keep existing keybindings:
      -- C-n / C-p: select next/prev (in default preset)
      -- C-b / C-f: scroll docs (in default preset)
      -- C-y: accept (in default preset)
      -- C-Space: show/toggle docs (in default preset)

      -- Snippet navigation via LuaSnip (replacing C-l / C-h)
      ['<C-l>'] = { 'snippet_forward', 'fallback' },
      ['<C-h>'] = { 'snippet_backward', 'fallback' },
    },

    snippets = { preset = 'luasnip' },

    completion = {
      list = { selection = { preselect = false, auto_insert = false } },
      documentation = { auto_show = true, auto_show_delay_ms = 200 },
      menu = {
        draw = {
          columns = {
            { 'label', 'label_description', gap = 1 },
            { 'kind_icon', 'kind' },
          },
        },
      },
    },

    cmdline = {
      keymap = {
        ['<Tab>'] = { 'show_and_insert_or_accept_single', 'select_next' },
        ['<S-Tab>'] = { 'show_and_insert_or_accept_single', 'select_prev' },
        ['<C-n>'] = { 'select_next', 'fallback' },
        ['<C-p>'] = { 'select_prev', 'fallback' },
        ['<C-y>'] = { 'select_and_accept', 'fallback' },
        ['<C-e>'] = { 'cancel', 'fallback' },
      },
    },

    sources = {
      default = { 'lsp', 'path', 'snippets', 'buffer' },
      per_filetype = {
        lua = { inherit_defaults = true, 'lazydev' },
      },
      providers = {
        lazydev = { name = 'LazyDev', module = 'lazydev.blink' },
      },
    },

    appearance = {
      nerd_font_variant = 'mono',
    },

    fuzzy = { implementation = 'prefer_rust_with_warning' },
  },
  opts_extend = { 'sources.default' },
}

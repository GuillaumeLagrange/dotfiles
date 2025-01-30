-- Disable netrw
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- Set to true if you have a Nerd Font installed
vim.g.have_nerd_font = true
vim.g.gruvbox_material_transparent_background = 1

-- [[ Setting options ]]
vim.opt.number = true
vim.opt.mouse = 'a'
-- Don't show the mode, since it's already in the status line
vim.opt.showmode = false
-- Sync clipboard between OS and Neovim.
vim.opt.clipboard = 'unnamedplus'
-- Enable break indent
vim.opt.breakindent = true
-- Save undo history
vim.opt.undofile = true
-- Case-insensitive searching UNLESS \C or one or more capital letters in the search term
vim.opt.ignorecase = true
vim.opt.smartcase = true
-- Keep signcolumn on by default
vim.opt.signcolumn = 'yes'
-- Decrease mapped sequence wait time
-- Displays which-key popup sooner
vim.opt.timeoutlen = 300
-- Configure how new splits should be opened
vim.opt.splitright = true
vim.opt.splitbelow = true
-- Sets how neovim will display certain whitespace characters in the editor.
vim.opt.list = true
vim.opt.listchars = { tab = '╎ ', trail = '·', nbsp = '␣' }
vim.opt.iskeyword:append('-')
-- Preview substitutions live, as you type!
vim.opt.inccommand = 'split'
-- Show which line your cursor is on
vim.opt.cursorline = true
-- Minimal number of screen lines to keep above and below the cursor.
vim.opt.scrolloff = 3
vim.opt.termguicolors = true

vim.opt.tabstop = 2

vim.opt.updatetime = 1000

vim.o.diffopt = 'internal,filler,closeoff,linematch:60,iwhite'
vim.o.wildignorecase = true

vim.o.foldmethod = 'expr'
vim.o.foldlevelstart = 99
vim.wo.foldexpr = 'v:lua.vim.treesitter.foldexpr()'

vim.o.swapfile = false
vim.o.autoread = true

vim.o.exrc = true

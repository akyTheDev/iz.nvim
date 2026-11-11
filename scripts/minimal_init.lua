-- Minimal init for headless test runs: only this plugin and mini.test.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:prepend(vim.fn.getcwd() .. "/deps/mini.nvim")
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"

require("mini.test").setup()

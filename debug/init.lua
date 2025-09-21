-- debug/init.lua
-- Minimal Neovim config to test snippet-browser.nvim with lazy.nvim

-- Add this repo (plugin root) to runtime path
vim.opt.rtp:prepend(vim.fn.fnamemodify(".", ":p"))

-- Load lazy.nvim and test plugins
require("debug.lazy")

-- Optional: basic settings so nvim feels normal
vim.opt.number = true
vim.opt.relativenumber = true


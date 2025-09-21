-- debug/lazy.lua
-- Setup lazy.nvim to test snippet-browser.nvim locally

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git", lazypath
  })
end
vim.opt.rtp:prepend(lazypath)

vim.g.mapleader = " "

require("lazy").setup({
  {
    dir = vim.fn.fnamemodify(".", ":p"), -- load the current plugin

    config = function()
      require("snipbrowzurr").setup({
        -- optional test config
        keymaps = {
          show = "<leader>ss",
          insert = "<C-y>",
        }
      })
    end,
  },
})



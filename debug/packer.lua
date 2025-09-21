-- debug/packer.lua
vim.cmd [[packadd packer.nvim]]

require("packer").startup(function(use)
  use "wbthomason/packer.nvim"
  use { dir = vim.fn.fnamemodify(".", ":p") } -- load current plugin
end)


-- debug/lazy.lua
-- Setup lazy.nvim to test snippet-browser.nvim locally

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
	vim.fn.system({
		"git",
		"clone",
		"--filter=blob:none",
		"https://github.com/folke/lazy.nvim.git",
		lazypath,
	})
end
vim.opt.rtp:prepend(lazypath)

-- Optional: sensible leader for testing
vim.g.mapleader = " "
vim.o.number = true
vim.o.relativenumber = true
vim.keymap.set("n", "<leader>-", "<cmd>Ex<CR>", { desc = "Open netrw" })
vim.keymap.set("n", "<leader>ws", "<cmd>w<CR>", { desc = "Save / Update current file" })
vim.keymap.set("n", "<leader>wq", "<cmd>wq<CR>", { desc = "Save and Quit" })
vim.keymap.set("n", "<leader><leader>x", "<cmd>source %<CR>")
vim.keymap.set("n", "<leader>x", ":.lua<CR>")
vim.keymap.set("v", "<leader>x", ":lua<CR>")

vim.cmd.colorscheme("default")

-- helper: path to this plugin repo root (where you placed debug/)
local repo_root = vim.fn.fnamemodify(".", ":p") -- ends with /

require("lazy").setup({
	-- LuaSnip (snippet engine)

	{
		"L3MON4D3/LuaSnip",
		dependencies = {
			"rafamadriz/friendly-snippets",
		},
		config = function()
			require("luasnip.loaders.from_vscode").lazy_load()
		end,
	},

	-- Your plugin under test (load from current directory)
	{
		dir = repo_root, -- load the current plugin directory
		dev = true, -- optional: enable dev mode (if you use lazy.nvim's dev features)
		config = function()
			-- IMPORTANT: snipbrowzurr.setup expects `keymap` (singular) per the plugin code
			require("snipbrowzurr").setup({
				snippets_path = vim.fn.stdpath("config") .. "snippets",
				load_vscode = true,
				load_lua = true,
				load_snipmate = true,
				keymap = "<leader>ss", -- open snippet browser
				-- other test options can go here
			})
		end,
	},
})

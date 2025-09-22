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

-- helper: path to this plugin repo root (where you placed debug/)
local repo_root = vim.fn.fnamemodify(".", ":p") -- ends with /

require("lazy").setup({
	-- LuaSnip (snippet engine)
	{
		"L3MON4D3/LuaSnip",
		dependencies = {
			-- optional collection of ready-to-use VSCode snippets
			"rafamadriz/friendly-snippets",
		},
		config = function()
			require("luasnip.loaders.from_vscode").load({})
		end,
	},

	-- Your plugin under test (load from current directory)
	{
		dir = repo_root, -- load the current plugin directory
		dev = true, -- optional: enable dev mode (if you use lazy.nvim's dev features)
		config = function()
			-- IMPORTANT: snipbrowzurr.setup expects `keymap` (singular) per the plugin code
			require("snipbrowzurr").setup({
				keymap = "<leader>ss", -- open snippet browser
				-- other test options can go here
			})
		end,
	},
})

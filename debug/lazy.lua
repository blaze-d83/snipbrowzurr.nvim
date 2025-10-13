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

-- robustly compute repo root as the parent directory of this file (debug/ -> repo root)
local this_file = debug.getinfo(1, "S").source:sub(2) -- remove leading '@'
local repo_root = vim.fn.fnamemodify(this_file, ":p:h:h") -- up two levels (file -> debug -> repo root)

-- plugin options for testing
local plugin_opts = {
	snippets_path = vim.fn.stdpath("config") .. "/snippets", -- ensure trailing slash
	view_mode = "two-column",
	preview = false,
	load_vscode = true,
	load_lua = true,
	load_snipmate = true,
	keymap = "<leader>ss", -- open snippet browser
}

require("lazy").setup({
	-- LuaSnip (snippet engine)
	{
		"L3MON4D3/LuaSnip",
		dependencies = {
			"rafamadriz/friendly-snippets",
		},
		config = function()
			-- load VSCode-style snippets shipped by friendly-snippets (optional)
			pcall(function()
				require("luasnip.loaders.from_vscode").lazy_load()
			end)
		end,
	},

	-- Your plugin under test (load from current repository)
	{
		dir = repo_root,
		dev = true,
		opts = plugin_opts,
		config = function(_, opts)
			-- pass opts directly (not wrapped)
			require("snipbrowzurr").setup(opts)
		end,
	},
})

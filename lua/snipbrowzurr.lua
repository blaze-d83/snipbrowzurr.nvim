-- lua/plugin/snipbrowzurr.lua
-- Minimal snippet browser for LuaSnip.
-- Shows a picker for snippets of current filetype and expands the chosen snippet
-- directly in the current window so placeholders remain jumpable.

local M = {}
local api = vim.api

-- safe require helper
local function safe_require(name)
	local ok, mod = pcall(require, name)
	if not ok then
		return nil
	end
	return mod
end

-- get filetype for current buffer (fallbacks to text)
local function get_filetype()
	local ft = vim.bo.filetype
	if ft and ft ~= "" then
		return ft
	end
	ft = vim.filetype.match({ buf = 0 }) or "text"
	return ft
end

-- produce a human label for a snippet object
local function snippet_label(sn)
	if not sn then
		return "<nil-snippet>"
	end

	-- try common fields coming from different loaders/representations
	local candidates = {
		sn.name,
		sn.description,
		sn.desc,
		sn.dscr,
		sn.descr,
		sn.trigger,
		sn.trig,
		sn.prefix,
		(sn.opts and sn.opts.description),
	}
	for _, v in ipairs(candidates) do
		if v and v ~= "" then
			return tostring(v)
		end
	end

	-- fallback to a compact inspect
	return vim.trim(vim.inspect(sn):gsub("\n", " "))
end

-- collect snippets for a filetype and return a numeric list
local function collect_snippets(filetype)
	local luasnip = safe_require("luasnip")
	if not luasnip then
		return {}
	end

	filetype = filetype or get_filetype()

	local ok, result = pcall(function()
		return luasnip.get_snippets(filetype)
	end)
	local raw = ok and result or nil

	if not raw then
		return {}
	end

	-- If it's an empty table -> no snippets
	if type(raw) == "table" and next(raw) == nil then
		return {}
	end

	-- Some loaders / versions wrap snippets in a `.tbl` field.
	if type(raw) == "table" and type(raw.tbl) == "table" then
		raw = raw.tbl
	end

	local list = {}

	-- Use vim.tbl_islist to detect list-shaped tables
	if type(raw) == "table" and vim.tbl_islist(raw) then
		for _, sn in ipairs(raw) do
			table.insert(list, sn)
		end
	else
		-- handle map shapes:
		for _, v in pairs(raw) do
			if type(v) == "table" then
				if vim.tbl_islist(v) then
					for _, sn in ipairs(v) do
						table.insert(list, sn)
					end
				else
					for _, sn in pairs(v) do
						table.insert(list, sn)
					end
				end
			end
		end
	end

	return list
end

-- derive a readable snippet body text. Best-effort for several snippet types.
local function snippet_body_text(sn)
	if not sn then
		return ""
	end

	-- VSCode JSON loader tends to keep `body`
	if type(sn.body) == "table" then
		return table.concat(sn.body, "\n")
	end
	if type(sn.body) == "string" then
		return sn.body
	end

	-- Some snippet objects produced by LuaSnip may expose get_doc()
	if type(sn.get_doc) == "function" then
		local ok, val = pcall(sn.get_doc, sn)
		if ok and val then
			return tostring(val)
		end
	end

	-- Some LuaSnip snippet objects expose nodes; best-effort inspect
	if sn.nodes and type(sn.nodes) == "table" and #sn.nodes > 0 then
		local out = {}
		for _, node in ipairs(sn.nodes) do
			table.insert(out, vim.inspect(node))
		end
		return table.concat(out, "\n\n")
	end

	-- fallback: show entire inspect of snippet object
	return vim.inspect(sn)
end

-- expand snippet (or paste fallback text) into target window/buffer
local function expand_snippet_in_window(winid, snip_or_text)
	local ls = safe_require("luasnip")
	if not ls then
		vim.notify("LuaSnip not found: cannot expand snippet", vim.log.levels.ERROR)
		return
	end

	-- switch to target window if valid (so expansion inserts in the right place)
	if winid and api.nvim_win_is_valid(winid) then
		api.nvim_set_current_win(winid)
	end

	-- Ensure we're in insert mode so placeholders can be active after expansion.
	if vim.fn.mode() ~= "i" then
		vim.cmd("startinsert")
	end

	local function try(fn)
		local ok, _ = pcall(fn)
		return ok
	end

	-- 1) If we're given a plain string, try lsp_expand (handles VSCode snippet syntax)
	if type(snip_or_text) == "string" and snip_or_text ~= "" then
		if
			try(function()
				-- some LuaSnip installs provide lsp_expand
				if ls.lsp_expand then
					ls.lsp_expand(snip_or_text)
				else
					-- fallback: try parser -> snip_expand
					if ls.parser and ls.parser.parse_snippet and ls.snip_expand then
						local parsed = ls.parser.parse_snippet(nil, snip_or_text, {})
						ls.snip_expand(parsed)
					else
						error("no lsp_expand/parser available")
					end
				end
			end)
		then
			return
		end
	end

	-- 2) If it's a table/snippet-like object, try a few strategies
	if type(snip_or_text) == "table" then
		local sn = snip_or_text

		-- 2a) VSCode loader style: body may be string or table
		if type(sn.body) == "string" then
			if
				try(function()
					if ls.lsp_expand then
						ls.lsp_expand(sn.body)
					elseif ls.parser and ls.parser.parse_snippet and ls.snip_expand then
						local parsed = ls.parser.parse_snippet(nil, sn.body, {})
						ls.snip_expand(parsed)
					else
						error("no lsp_expand/parser available")
					end
				end)
			then
				return
			end
		elseif type(sn.body) == "table" then
			local body = table.concat(sn.body, "\n")
			if
				try(function()
					if ls.lsp_expand then
						ls.lsp_expand(body)
					elseif ls.parser and ls.parser.parse_snippet and ls.snip_expand then
						local parsed = ls.parser.parse_snippet(nil, body, {})
						ls.snip_expand(parsed)
					else
						error("no lsp_expand/parser available")
					end
				end)
			then
				return
			end
		end

		-- 2b) Some snippet objects expose a get_doc() that returns a textual body
		if type(sn.get_doc) == "function" then
			local ok, doc = pcall(sn.get_doc, sn)
			if ok and type(doc) == "string" and doc ~= "" then
				if
					try(function()
						if ls.lsp_expand then
							ls.lsp_expand(doc)
						elseif ls.parser and ls.parser.parse_snippet and ls.snip_expand then
							local parsed = ls.parser.parse_snippet(nil, doc, {})
							ls.snip_expand(parsed)
						else
							error("no lsp_expand/parser available")
						end
					end)
				then
					return
				end
			end
		end

		-- 2c) If this looks like a LuaSnip snippet object (nodes present), expand it directly
		if sn.nodes and type(sn.nodes) == "table" and #sn.nodes > 0 then
			-- try snip_expand (LuaSnip object expansion)
			if
				try(function()
					-- prefer snip_expand if exposed
					if ls.snip_expand then
						ls.snip_expand(sn)
					else
						-- as a fallback, try to parse snippet body text and expand
						local body = snippet_body_text(sn)
						if ls.parser and ls.parser.parse_snippet and ls.snip_expand then
							local parsed = ls.parser.parse_snippet(nil, body, {})
							ls.snip_expand(parsed)
						else
							error("no snip_expand/parser available")
						end
					end
				end)
			then
				return
			end
		end
	end

	-- 3) Try parsing a string into a snippet then expanding that (useful fallback)
	if
		type(snip_or_text) == "string"
		and snip_or_text ~= ""
		and ls.parser
		and ls.parser.parse_snippet
		and ls.snip_expand
	then
		if
			try(function()
				local parsed = ls.parser.parse_snippet(nil, snip_or_text, {})
				ls.snip_expand(parsed)
			end)
		then
			return
		end
	end

	-- Last resort: insert readable fallback text (avoid inserting huge inspect blobs when possible)
	local text = snippet_body_text(snip_or_text)
	api.nvim_put(vim.split(text, "\n", { plain = true }), "c", true, true)
	vim.notify("Snippet expansion failed; inserted fallback text", vim.log.levels.WARN)
end

-- main entry: show a selection of snippets for current ft
function M.show(opts)
	opts = opts or {}
	local ft = opts.filetype or get_filetype()
	local snippets = collect_snippets(ft)

	if #snippets == 0 then
		vim.notify("No snippets found for filetype: " .. ft, vim.log.levels.INFO)
		return
	end

	local items = {}
	for i, sn in ipairs(snippets) do
		table.insert(items, {
			label = snippet_label(sn),
			trigger = (sn.trigger or sn.trig or sn.prefix or ""),
			raw = sn,
			idx = i,
		})
	end

	vim.ui.select(items, {
		prompt = string.format("Snippets for %s (%d):", ft, #items),
		format_item = function(item)
			local trig = item.trigger ~= "" and (" [" .. item.trigger .. "]") or ""
			return item.label .. trig
		end,
	}, function(choice)
		if not choice then
			return
		end
		-- expand in the original window so placeholders remain usable
		local orig_win = api.nvim_get_current_win()
		expand_snippet_in_window(orig_win, choice.raw)
	end)
end

function M.show_current()
	M.show({ filetype = get_filetype() })
end

-- setup with optional options:
-- { keymap = "<leader>ss", load_vscode = true, vscode_snippets_path = ... }
function M.setup(user_opts)
	user_opts = user_opts or {}
	local keymap = user_opts.keymap or "<leader>ss"

	-- create a command
	api.nvim_create_user_command("LuaSnipList", function()
		M.show_current()
	end, { desc = "Show LuaSnip snippets for current file" })

	-- create keymap if desired
	if keymap and keymap ~= "" then
		vim.keymap.set("n", keymap, function()
			M.show_current()
		end, { desc = "Show snippets for current file" })
	end

	-- optional: lazy-load vscode snippets from a path (default: ~/.config/nvim/snippets)
	if user_opts.load_vscode ~= false then
		local ok, loader = pcall(require, "luasnip.loaders.from_vscode")
		if ok and loader and user_opts.vscode_snippets_path ~= false then
			local path = user_opts.vscode_snippets_path or (vim.fn.stdpath("config") .. "/snippets")
			pcall(function()
				loader.lazy_load({ paths = { path } })
			end)
		end
	end
end

return M

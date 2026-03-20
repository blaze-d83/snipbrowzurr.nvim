-- lua/plugin/snipbrowzurr.lua

local M = {}
local api = vim.api

-- Default configuration (documented)
M._defaults = {
	keymap = "<leader>ss", -- string | false (don't create keymap)
	snippets_path = nil, -- nil (use stdpath) | string | table

	-- Preview
	preview = true, -- boolean: show preview window by default
	preview_side_margin = 2,
	preview_max_width = 40,

	-- These are optional users are expected to load them in LuaSnip
	load_vscode = false, -- boolean: lazy-load vscode loaders
	load_lua = false, -- boolean: lazy-load lua loaders
	load_snipmate = false, -- boolean: lazy-load snipmate loaders

	on_select = nil, -- function(choice, ctx) => if returns true, treat as handled
}

-- Internal cache for snippet entries per filetype
local _cache = {}

-- Helper: safe require (returns ok, module_or_error)
local function safe_require(name)
	local ok, mod_or_err = pcall(require, name)
	return ok, mod_or_err
end

-- Determine the filetype of the current buffer
local function get_filetype()
	local ft = vim.bo.filetype
	if ft and ft ~= "" then
		return ft
	end
	return vim.filetype.match({ buf = 0 }) or "text"
end

-- Check if raw data looks like snippet
local function look_like_a_snippet(tbl)
	if type(tbl) ~= "table" then
		return false
	end

	-- Looks like a snippet if it contains:
	if tbl.body or tbl.trigger or tbl.prefix or tbl.get_doc or tbl.nodes then
		return true
	end
	return false
end

-- Flatten nested snippet table returned by LuaSnip into a flat array
local function flatten_snippets(raw, out, visited)
	out = out or {}
	visited = visited or {}
	if type(raw) ~= "table" then
		return out
	end
	if visited[raw] then
		return out
	end
	visited[raw] = true

	for _, v in pairs(raw) do
		if type(v) == "table" then
			if vim.islist(v) then
				for _, e in ipairs(v) do
					if type(e) == "table" then
						flatten_snippets(e, out, visited)
					end
				end
			else
				if look_like_a_snippet(v) then
					if not visited[v] then
						visited[v] = true
						table.insert(out, v)
					end
				else
					flatten_snippets(v, out, visited)
				end
			end
		end
	end

	return out
end

-- Collect snippets for a filetype using LuaSnip (safe)
local function collect_snippets(filetype)

	local ok, ls = safe_require("luasnip")
	if not ok or not ls then
		return {}
	end

	filetype = filetype or get_filetype()

	-- LuaSnip API get_snippets
	local ok2, raw = pcall(function()
		if ls.get_snippets then
			return ls.get_snippets(filetype)
		end
		return ls.snippets and ls.snippets[filetype]
	end)
	if not ok2 or not raw or next(raw) == nil then
		return {}
	end
	if type(raw) == "table" and type(raw.tbl) == "table" then
		raw = raw.tbl
	end
	return flatten_snippets(raw, {}, {})
end

-- Generate human readable label for a snippet
local function snippet_label(sn)
	if not sn then
		return "<nil-snippet>"
	end
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
	local ok, s = pcall(function()
		return vim.inspect(sn)
	end)
	if ok and s then
		return vim.trim(s:gsub("\n", " "))
	end
	return "<snippet>"
end

-- Convert snippet body to plain text for fallback insertion
local function snippet_body_text(sn)
	if not sn then
		return ""
	end
	if type(sn.body) == "table" then
		return table.concat(sn.body, "\n")
	end
	if type(sn.body) == "string" then
		return sn.body
	end
	if type(sn.get_doc) == "function" then
		local ok, val = pcall(sn.get_doc, sn)
		if ok and val and type(val) == "string" then
			return val
		end
	end
	if sn.nodes and type(sn.nodes) == "table" and #sn.nodes > 0 then
		local out = {}
		for _, node in ipairs(sn.nodes) do
			table.insert(out, vim.inspect(node))
		end
		return table.concat(out, "\n\n")
	end
	local ok, s = pcall(function()
		return vim.inspect(sn)
	end)
	return (ok and s) or ""
end

-- Preview snippet body (no blob)
local function preview_body_text(sn)
	if not sn then
		return "(empty snippet body)"
	end

	if type(sn.get_docstring) == "function" then
		local ok, doc = pcall(sn.get_docstring, sn)
		if ok and type(doc) == "table" and #doc > 0 then
			return table.concat(doc, "\n")
		end
	end
	if type(sn.docstring) == "table" and #sn.docstring > 0 then
		return table.concat(sn.docstring, "\n")
	end
	if type(sn.docstring) == "string" and sn.docstring ~= "" then
		return sn.docstring
	end

	local body = snippet_body_text(sn)
	if body ~= "" then
		body = body:gsub("%${%d+:([^}]*)}", "%1")
		body = body:gsub("%${%d+|([^|]*)|}", function(c)
			return c:match("^([^,]*)") or c
		end)
		body = body:gsub("%${%d+}", "")
		body = body:gsub("%$%d+", "")
		body = body:gsub("\n\n\n+", "\n\n")
		return vim.trim(body)
	end

	return "(empty snippet body)"
end

-- Try expanding text via LuaSnip extension points
local function try_expand_with_text(ls, text)
	if not text or text == "" then
		return false
	end
	local function try_one(fn)
		local ok, _ = pcall(fn)
		return ok
	end
	if ls.lsp_expand then
		if try_one(function()
			ls.lsp_expand(text)
		end) then
			return true
		end
	end
	if ls.parser and ls.parser.parse_snippet and ls.snip_expand then
		if
			try_one(function()
				local parsed = ls.parser.parse_snippet(nil, text, {})
				ls.snip_expand(parsed)
			end)
		then
			return true
		end
	end
	return false
end

-- Insert text at the current cursor position using buffer API
local function insert_text_at_cursor(text, winid)
	local txt = text or ""
	local win = (winid and api.nvim_win_is_valid(winid)) and winid or api.nvim_get_current_win()
	local buf = api.nvim_win_get_buf(win)
	unpack = table.unpack or unpack
	local row, col = unpack(api.nvim_win_get_cursor(win))
	local lines = vim.split(txt, "\n", { plain = true })
	-- set_text expects 0-indexed row/col
	pcall(api.nvim_buf_set_text, buf, row - 1, col, row - 1, col, lines)
	-- move cursor to end of inserted text
	local last_line = #lines
	local last_col = #lines[last_line]
	pcall(api.nvim_win_set_cursor, win, { row + last_line - 1, last_col })
end

-- Expand snippet (or fallback insert text) in a given window
local function expand_snippet_in_window(winid, snip_or_text)
	local ok, ls = safe_require("luasnip")
	if not ok or not ls then
		vim.notify("LuaSnip not found: cannot expand snippet", vim.log.levels.ERROR)
		return
	end
	if winid and api.nvim_win_is_valid(winid) then
		api.nvim_set_current_win(winid)
	end
	if vim.fn.mode() ~= "i" then
		vim.cmd("startinsert!")
	end

	if type(snip_or_text) == "string" and snip_or_text ~= "" then
		if try_expand_with_text(ls, snip_or_text) then
			return
		end
	end

	if type(snip_or_text) == "table" then
		local sn = snip_or_text
		if type(sn.body) == "string" then
			if try_expand_with_text(ls, sn.body) then
				return
			end
		elseif type(sn.body) == "table" then
			local body = table.concat(sn.body, "\n")
			if try_expand_with_text(ls, body) then
				return
			end
		end
		if type(sn.get_doc) == "function" then
			local ok2, doc = pcall(sn.get_doc, sn)
			if ok2 and type(doc) == "string" and doc ~= "" then
				if try_expand_with_text(ls, doc) then
					return
				end
			end
		end
		if sn.nodes and type(sn.nodes) == "table" and #sn.nodes > 0 then
			local ok2, _ = pcall(function()
				if ls.snip_expand then
					ls.snip_expand(sn)
				else
					local body = snippet_body_text(sn)
					local parsed = ls.parser and ls.parser.parse_snippet and ls.parser.parse_snippet(nil, body, {})
					if parsed and ls.snip_expand then
						ls.snip_expand(parsed)
					else
						error("no snip_expand available")
					end
				end
			end)
			if ok2 then
				return
			end
		end
	end

	if
		type(snip_or_text) == "string"
		and snip_or_text ~= ""
		and ls.parser
		and ls.parser.parse_snippet
		and ls.snip_expand
	then
		local ok3, _ = pcall(function()
			local parsed = ls.parser.parse_snippet(nil, snip_or_text, {})
			ls.snip_expand(parsed)
		end)
		if ok3 then
			return
		end
	end

	-- Fallback: Insert plain text insertion into buffer (safer path)
	local text = snippet_body_text(snip_or_text)
	insert_text_at_cursor(text, winid)
	vim.notify("Snippet expansion failed; inserted fallback text", vim.log.levels.WARN)
end

-- Build snippet entries
local function build_entries_for_ft(ft)
	ft = ft or get_filetype()
	if _cache[ft] and vim.tbl_count(_cache[ft]) > 0 then
		return _cache[ft]
	end

	local raw = collect_snippets(ft)
	local items = {}
	local seen = {}
	for _, sn in ipairs(raw) do
		if not seen[sn] then
			seen[sn] = true
			local trigger = sn.trigger or sn.trig or sn.prefix or ""
			local label = snippet_label(sn)
			local display = string.format("%s\t%s", trigger, label:gsub("\t", "   "))
			table.insert(items, { display = display, raw = sn, trigger = trigger, label = label })
		end
	end
	_cache[ft] = items
	return items
end

function M.clear_cache(filetype)
	if filetype then
		_cache[filetype] = nil
	else
		_cache = {}
	end
end

-- Expands snippet in editor window on <enter>
local function expand_selected_entries(entries_map, selected, winid)
	if not selected or #selected == 0 then
		return
	end
	for _, sel in ipairs(selected) do
		local e = entries_map[sel]
		if e then
			local handled = false
			if type(M._defaults.on_select) == "function" then
				local ok, result = pcall(M._defaults.on_select, e, { winid = winid })
				handled = ok and result == true
			end
			if not handled then
				expand_snippet_in_window(winid, e.raw)
			end
		end
	end
end

-- Build and show the UI
function M.show(call_opts)
	-- Merge stored setup opts with per-call opts; call_opts take precedence
	call_opts = call_opts or {}

	local cfg = vim.tbl_extend("force", M._defaults, call_opts)

	local ft = (cfg.filetype and cfg.filetype ~= "") and cfg.filetype or get_filetype()
	local entries = build_entries_for_ft(ft)

	if not entries or #entries == 0 then
		vim.notify("No snippets found for filetype: " .. ft, vim.log.levels.INFO)
		return
	end

	-- Prepare a map value for fzf-lua
	local display_list = {}
	local entries_map = {}
	for _, e in ipairs(entries) do
		display_list[#display_list + 1] = e.display
		entries_map[e.display] = e
	end

	-- Prepare sanitized data for fzf-preview
	local preview_fn = function(items)
		local e = entries_map[items[1]]
		if not e then
			return "No preview available"
		end
		return preview_body_text(e.raw)
	end

    -- Fzf
	local ok, fzf = safe_require("fzf-lua")
	if ok and type(fzf.fzf_exec) == "function" then
		local orig_win = api.nvim_get_current_win()
		local ok_shell, fzf_shell = safe_require("fzf-lua.shell")
		if not ok_shell then
			vim.notify("fzf-lua.shell not available", vim.log.levels.ERROR)
			return
		end
		local fzf_opts = {
			prompt = "Search > ",
			previewer = false,
			preview = preview_fn,
			winopts = {
				preview = {
					hidden = cfg.preview and "nohidden" or "hidden",
					layout = "vertical",
					vertical = "down:40%",
				},
			},

			actions = {

				["default"] = function(selected)
					expand_selected_entries(entries_map, selected, orig_win)
				end,
			},
		}

		fzf.fzf_exec(display_list, fzf_opts)
		return
	end

    -- vim UI (fallback if fzf not setup)
	local orig_win = api.nvim_get_current_win()

	vim.ui.select(entries, {
		prompt = "Search",
		format_item = function(item)
			return item.display
		end,
	}, function(item)
		if not item then
			return
		end
		expand_snippet_in_window(orig_win, item.raw)
	end)
end

-- Simple helper to call show for current filetype using stored defaults
function M.open(opts)
	M.show(opts)
end

-- Setup: merge & persist user options, create command & keymap, and load snippet loaders
function M.setup(opts)
	opts = opts or {}
	M._defaults = vim.tbl_extend("force", M._defaults, opts)

	local ok, ls = safe_require("luasnip")
	if ok and ls then
		if M._defaults.load_vscode then
			pcall(function()
				require("luasnip.loaders.from_vscode").lazy_load()
			end)
		end
		if M._defaults.load_lua then
			pcall(function()
				require("luasnip.loaders.from_lua").lazy_load()
			end)
		end
		if M._defaults.load_snipmate then
			pcall(function()
				require("luasnip.loaders.from_snipmate").lazy_load()
			end)
		end
	end

	if M._defaults.keymap and type(M._defaults.keymap) == "string" and M._defaults.keymap ~= "" then
		pcall(vim.keymap.set, "n", M._defaults.keymap, function()
			M.open()
		end, { noremap = true, silent = true, desc = "Snipbrowzurr: search snippets" })
	end
end

return M

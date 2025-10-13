-- lua/plugin/snipbrowzurr.lua
-- Minimal snippet browser for LuaSnip (search & selection improvements)
-- Option handling follows best practices:
--  - M.setup(user_opts) merges user_opts with M._defaults and stores in M._opts
--  - M.show(call_opts) merges call_opts on top of M._opts so per-call overrides work
--  - setup creates the keymap/command that call M.show() using stored defaults

local M = {}
local api = vim.api

-- Default configuration (documented)
M._defaults = {
	keymap = "<leader>ss", -- string | false (don't create keymap)
	snippets_path = nil, -- nil (use stdpath) | string | table
	view = "list", -- "list" | "two-column" (accepts view_mode alias)
	preview = false, -- boolean: show preview window by default
	preview_side_margin = 2,
	preview_max_width = 40,
	load_vscode = true, -- boolean: lazy-load vscode loaders
	load_lua = true, -- boolean: lazy-load lua loaders
	load_snipmate = true, -- boolean: lazy-load snipmate loaders
	on_select = nil, -- function(choice, ctx) => if returns true, treat as handled
}

-- Helper: safe require
local function safe_require(name)
	local ok, mod = pcall(require, name)
	if not ok then
		return nil
	end
	return mod
end

-- Determine the filetype of the current buffer
local function get_filetype()
	local ft = vim.bo.filetype
	if ft and ft ~= "" then
		return ft
	end
	return vim.filetype.match({ buf = 0 }) or "text"
end

-- UTF-8-safe truncate by display width
local function utf8_truncate(s, max_width)
	if not s or max_width <= 0 then
		return ""
	end
	if vim.fn.strdisplaywidth(s) <= max_width then
		return s
	end

	local ell = "…"
	local ell_w = vim.fn.strdisplaywidth(ell)
	local out = ""
	local w = 0

	for uchar in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		local cw = vim.fn.strdisplaywidth(uchar)
		if w + cw + ell_w > max_width then
			out = out .. ell
			break
		end
		out = out .. uchar
		w = w + cw
	end
	return out
end

-- Pad a string to a target display width
local function pad_to_display(s, target_w)
	s = s or ""
	local cur_w = vim.fn.strdisplaywidth(s)
	if cur_w >= target_w then
		return s
	end
	return s .. string.rep(" ", target_w - cur_w)
end

-- UTF-8 aware iterator -> array of characters
local function utf8_iter(s)
	local out = {}
	if not s or s == "" then
		return out
	end
	for uchar in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		table.insert(out, uchar)
	end
	return out
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

	if vim.islist(raw) then
		for _, v in ipairs(raw) do
			if type(v) == "table" then
				flatten_snippets(v, out, visited)
			end
		end
		return out
	end

	local function look_like_a_snippet(tbl)
		if type(tbl) ~= "table" then
			return false
		end
		if tbl.body or tbl.trigger or tbl.prefix or tbl.get_doc or tbl.nodes then
			return true
		end
		return false
	end

	if look_like_a_snippet(raw) then
		table.insert(out, raw)
		return out
	end

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
					table.insert(out, v)
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
	local ls = safe_require("luasnip")
	if not ls then
		return {}
	end
	filetype = filetype or get_filetype()
	local ok, raw = pcall(function()
		return ls.get_snippets(filetype)
	end)
	if not ok or not raw or next(raw) == nil then
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

-- Expand snippet (or fallback insert text) in a given window
local function expand_snippet_in_window(winid, snip_or_text)
	local ls = safe_require("luasnip")
	if not ls then
		vim.notify("LuaSnip not found: cannot expand snippet", vim.log.levels.ERROR)
		return
	end
	if winid and api.nvim_win_is_valid(winid) then
		api.nvim_set_current_win(winid)
	end
	if vim.fn.mode() ~= "i" then
		vim.cmd("startinsert")
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
			local ok, doc = pcall(sn.get_doc, sn)
			if ok and type(doc) == "string" and doc ~= "" then
				if try_expand_with_text(ls, doc) then
					return
				end
			end
		end
		if sn.nodes and type(sn.nodes) == "table" and #sn.nodes > 0 then
			local ok, _ = pcall(function()
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
			if ok then
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
		local ok, _ = pcall(function()
			local parsed = ls.parser.parse_snippet(nil, snip_or_text, {})
			ls.snip_expand(parsed)
		end)
		if ok then
			return
		end
	end

	-- Fallback: Insert plain text insertion into buffer
	local text = snippet_body_text(snip_or_text)
	api.nvim_put(vim.split(text, "\n", { plain = true }), "c", true, true)
	vim.notify("Snippet expansion failed; inserted fallback text", vim.log.levels.WARN)
end

-- Safe window/buffer helpers
local function safe_close_win(win)
	if win and api.nvim_win_is_valid(win) then
		pcall(api.nvim_win_close, win, true)
	end
end

local function safe_delete_buf(buf)
	if buf and api.nvim_buf_is_valid(buf) then
		pcall(api.nvim_buf_delete, buf, { force = true })
	end
end

-- Simple fuzzy subsequence match (UTF-8 aware)
local function fuzzy_match(hay, pat)
	if not pat or pat == "" then
		return true
	end
	if not hay or hay == "" then
		return false
	end

	hay = hay:lower()
	pat = pat:lower()

	local hchars = utf8_iter(hay)
	local pchars = utf8_iter(pat)
	local hi = 1

	for _, pc in ipairs(pchars) do
		if pc ~= " " then
			local found = nil
			for j = hi, #hchars do
				if hchars[j] == pc then
					found = j
					break
				end
			end
			if not found then
				return false
			end
			hi = found + 1
		end
	end
	return true
end

-- Build and show the UI
function M.show(call_opts)
	-- Ensure stored setup opts exist
	if not M._opts then
		M._opts = vim.tbl_extend("force", {}, M._defaults)
	end

	-- Merge stored setup opts with per-call opts; call_opts take precedence
	call_opts = call_opts or {}
	-- Accept alias view_mode -> view if provided per-call
	if call_opts.view_mode and not call_opts.view then
		call_opts.view = call_opts.view_mode
	end
	local cfg = vim.tbl_extend("force", M._opts, call_opts)

	-- resolved UI options
	local ft = cfg.filetype or get_filetype()
	local snippets = collect_snippets(ft)
	local view_mode = (cfg.view and tostring(cfg.view)) or "list"
	local preview_enabled = (cfg.preview == true)

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

	-- window options (compute based on current screen size)
	local orig_win = api.nvim_get_current_win()
	local width = math.min(80, math.max(40, math.floor(vim.o.columns * 0.6)))
	local height = math.min(20, math.max(6, math.floor(vim.o.lines * 0.4)))
	local search_h = 1
	local list_h = math.max(3, height - search_h)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	-- create buffers
	local search_buf = api.nvim_create_buf(false, true)
	local list_buf = api.nvim_create_buf(false, true)

	api.nvim_set_option_value("bufhidden", "wipe", { buf = search_buf })
	api.nvim_set_option_value("bufhidden", "wipe", { buf = list_buf })
	api.nvim_set_option_value("buftype", "nofile", { buf = search_buf })
	api.nvim_set_option_value("buftype", "nofile", { buf = list_buf })
	api.nvim_set_option_value("modifiable", true, { buf = search_buf })
	api.nvim_set_option_value("modifiable", false, { buf = list_buf })
	api.nvim_set_option_value("filetype", "snipbrowzurr_search", { buf = search_buf })
	pcall(api.nvim_buf_set_name, search_buf, "SnipSearch")
	pcall(api.nvim_buf_set_lines, search_buf, 0, -1, false, { "" })

	-- search window
	local search_win = api.nvim_open_win(search_buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = search_h,
		style = "minimal",
		border = "single",
		title = "Search",
	})

	-- list window
	local list_win = api.nvim_open_win(list_buf, true, {
		relative = "editor",
		row = row + search_h,
		col = col,
		width = width,
		height = list_h,
		style = "minimal",
		border = "rounded",
		title = string.format("Snippets for %s (%d)", ft, #items),
	})

	-- state: filtered list and selected index
	local filtered = vim.deepcopy(items)
	local selected_idx = (#filtered > 0) and 1 or 0
	local list_offset = 1
	local ns = api.nvim_create_namespace("snipbrowzurr")

	-- format display for an item
	local function format_item_display(it, is_selected)
		local prefix = is_selected and "> " or " "
		local trig = it.trigger ~= "" and ("[" .. it.trigger .. "]") or ""
		local label = (it.label or ""):gsub("\t", " ")

		if view_mode == "two-column" then
			local gutter = 1
			local prefix_w = vim.fn.strdisplaywidth(prefix)
			local avail = math.max(10, width - prefix_w - 2)
			local left_w = math.min(math.max(8, math.floor(avail * 0.25)), 30)
			local right_w = math.max(10, avail - left_w - gutter)

			local left_txt = utf8_truncate(trig, left_w)
			local right_txt = utf8_truncate(label, right_w)

			local left_pad = pad_to_display(left_txt, left_w)
			local right_pad = pad_to_display(right_txt, right_w)
			return prefix .. left_pad .. string.rep(" ", gutter) .. right_pad
		else
			local trig_part = trig ~= "" and (" " .. trig) or ""
			local out = prefix .. label .. trig_part

			local max_w = math.max(10, width - 2)
			return utf8_truncate(out, max_w)
		end
	end

	local function clamp(v, a, b)
		return math.max(a, math.min(b, v))
	end

	local function max_offset(total, h)
		return math.max(1, total - h + 1)
	end

	-- render list window
	local function render_list()
		local lines = {}
		local total = #filtered
		list_offset = clamp(list_offset, 1, max_offset(total, list_h))

		local start_idx = list_offset
		local end_idx = math.min(total, list_offset + list_h - 1)

		for i = start_idx, end_idx do
			local it = filtered[i]
			lines[#lines + 1] = format_item_display(it, (i == selected_idx))
		end

		api.nvim_set_option_value("modifiable", true, { buf = list_buf })
		api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
		api.nvim_set_option_value("modifiable", false, { buf = list_buf })

		api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)
		if selected_idx >= 1 and selected_idx <= total then
			local visible_row = selected_idx - list_offset
			if visible_row >= 0 and visible_row < #lines then
				pcall(api.nvim_buf_set_extmark, list_buf, ns, visible_row, 0, { hl_group = "Visual", ephemeral = true })
			end
		end
		-- Note: do NOT change windows/cursor here (we keep focus in search buffer)
	end

	render_list()

	-- cleanup function
	local function close_popup()
		safe_close_win(search_win)
		safe_close_win(list_win)
		safe_delete_buf(search_buf)
		safe_delete_buf(list_buf)
		if orig_win and api.nvim_win_is_valid(orig_win) then
			api.nvim_set_current_win(orig_win)
		end
	end

	-- selection behaviour: call on_select callback if present, otherwise expand
	local function select_current()
		if selected_idx < 1 or selected_idx > #filtered then
			return
		end
		local choice = filtered[selected_idx]
		close_popup()
		if not choice then
			return
		end

		-- If user supplied on_select and it returns true, assume handled
		if cfg.on_select and type(cfg.on_select) == "function" then
			local ok, handled = pcall(cfg.on_select, choice.raw, { orig_win = orig_win, index = selected_idx })
			if ok and handled == true then
				return
			end
		end

		-- default behavior: expand snippet into original window
		expand_snippet_in_window(orig_win, choice.raw)
	end

	-- change selection
	local function change_selection(delta)
		if #filtered == 0 then
			return
		end
		selected_idx = clamp(selected_idx + delta, 1, #filtered)
		if selected_idx > list_offset + list_h - 1 then
			list_offset = selected_idx - list_h + 1
		elseif selected_idx < list_offset then
			list_offset = selected_idx
		end

		list_offset = clamp(list_offset, 1, max_offset(#filtered, list_h))
		render_list()
	end

	local function set_selection(index)
		if #filtered == 0 then
			selected_idx = 0
			list_offset = 1
			render_list()
			return
		end
		selected_idx = clamp(index, 1, #filtered)
		if selected_idx > list_offset + list_h - 1 then
			list_offset = selected_idx - list_h + 1
		elseif selected_idx < list_offset then
			list_offset = selected_idx
		end
		list_offset = clamp(list_offset, 1, max_offset(#filtered, list_h))
		render_list()
	end

	-- filtering logic
	local function do_filter()
		local ok, lines = pcall(api.nvim_buf_get_lines, search_buf, 0, -1, false)
		if not ok then
			return
		end
		local q = (lines and lines[1]) or ""
		q = vim.trim(q)
		if q == "" then
			filtered = items
		else
			local tokens = {}
			for token in q:gmatch("%S+") do
				table.insert(tokens, token)
			end
			local newf = {}
			for _, it in ipairs(items) do
				local hay = (it.label or "") .. " " .. (it.trigger or "")
				local ok_all = true
				for _, tok in ipairs(tokens) do
					if not fuzzy_match(hay, tok) then
						ok_all = false
						break
					end
				end
				if ok_all then
					table.insert(newf, it)
				end
			end
			filtered = newf
		end

		-- adjust selection
		if #filtered > 0 then
			selected_idx = 1
			list_offset = 1
		else
			selected_idx = 0
			list_offset = 1
		end
		if #filtered == 0 then
			api.nvim_set_option_value("modifiable", true, { buf = list_buf })
			api.nvim_buf_set_lines(list_buf, 0, -1, false, { "<no matches>" })
			api.nvim_set_option_value("modifiable", false, { buf = list_buf })
			api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)
		else
			render_list()
		end
	end

	-- attach to search buffer for live filtering
	if api.nvim_buf_is_valid(search_buf) then
		api.nvim_buf_attach(search_buf, false, {
			on_lines = function()
				vim.schedule(do_filter)
				return true
			end,
		})
	end

	-- mappings for search buffer (insert mode friendly)
	vim.keymap.set("i", "<CR>", function()
		select_current()
	end, { buffer = search_buf, silent = true })

	local nav_fn = function(delta)
		return function()
			change_selection(delta)
			vim.cmd("startinsert")
		end
	end

	vim.keymap.set("i", "<C-n>", nav_fn(1), { buffer = search_buf, silent = true })
	vim.keymap.set("i", "<C-p>", nav_fn(-1), { buffer = search_buf, silent = true })
	vim.keymap.set("i", "<C-j>", nav_fn(1), { buffer = search_buf, silent = true })
	vim.keymap.set("i", "<C-k>", nav_fn(-1), { buffer = search_buf, silent = true })

	-- normal mode navigation on search buffer
	vim.keymap.set("n", "<Down>", function()
		change_selection(1)
	end, { buffer = search_buf, silent = true })
	vim.keymap.set("n", "<Up>", function()
		change_selection(-1)
	end, { buffer = search_buf, silent = true })

	-- list buffer mappings
	vim.keymap.set("n", "j", function()
		change_selection(1)
	end, { buffer = list_buf, silent = true })
	vim.keymap.set("n", "k", function()
		change_selection(-1)
	end, { buffer = list_buf, silent = true })
	vim.keymap.set("n", "<C-n>", function()
		change_selection(1)
	end, { buffer = list_buf, silent = true })
	vim.keymap.set("n", "<C-p>", function()
		change_selection(-1)
	end, { buffer = list_buf, silent = true })
	vim.keymap.set("n", "<CR>", function()
		select_current()
	end, { buffer = list_buf, silent = true })

	-- close mappings (both buffers); support closing from insert by mapping <Esc> in insert-mode search buffer
	vim.keymap.set("i", "<Esc>", function()
		-- leave insert then close
		vim.cmd("stopinsert")
		close_popup()
	end, { buffer = search_buf, silent = true })

	vim.keymap.set("n", "<Esc>", function()
		close_popup()
	end, { buffer = search_buf, silent = true })
	vim.keymap.set("n", "<Esc>", function()
		close_popup()
	end, { buffer = list_buf, silent = true })

	-- focus search buffer and enter insert
	api.nvim_set_current_win(search_win)
	vim.cmd("startinsert")
end

-- Simple helper to call show for current filetype using stored defaults
function M.show_current()
	M.show()
end

-- Setup: merge & persist user options, create command & keymap, and load snippet loaders
function M.setup(user_opts)
	-- Normalize alias and merge with defaults
	user_opts = user_opts or {}
	if user_opts.view_mode and not user_opts.view then
		user_opts.view = user_opts.view_mode
	end

	-- Merge (call opts override defaults here not relevant; this is setup-time)
	M._opts = vim.tbl_extend("force", {}, M._defaults, user_opts)

	-- Validate a few fields (fail fast for common mistakes)
	if M._opts.keymap and M._opts.keymap ~= false and type(M._opts.keymap) ~= "string" then
		error("snipbrowzurr: keymap must be string or false")
	end
	if M._opts.preview ~= nil and type(M._opts.preview) ~= "boolean" then
		error("snipbrowzurr: preview must be boolean")
	end
	if M._opts.view and type(M._opts.view) ~= "string" then
		error("snipbrowzurr: view must be a string ('list' or 'two-column')")
	end
	if M._opts.on_select and type(M._opts.on_select) ~= "function" then
		error("snipbrowzurr: on_select must be a function or nil")
	end

	-- Resolve snippets path default if not provided (preserve nil vs empty string)
	local default_path = vim.fn.stdpath("config") .. "/snippets"
	local resolved_path
	if M._opts.snippets_path ~= nil and M._opts.snippets_path ~= "" then
		resolved_path = M._opts.snippets_path
	else
		resolved_path = default_path
	end

	-- Create user command (uses stored defaults)
	api.nvim_create_user_command("LuaSnipList", function()
		M.show()
	end, { desc = "Show LuaSnip snippets for current file" })

	-- Create keymap if requested
	if M._opts.keymap and M._opts.keymap ~= "" then
		vim.keymap.set("n", M._opts.keymap, function()
			M.show()
		end, { desc = "Show snippets for current file" })
	end

	-- Loader function that references setup-time options (M._opts)
	local setup_opts = M._opts
	local function load_loader(flag_name, loader_module, path_key_name, default_paths)
		if setup_opts[flag_name] == false then
			return
		end
		local ok, loader = pcall(require, loader_module)
		if not ok or type(loader) ~= "table" then
			return
		end

		local user_paths
		if path_key_name and setup_opts[path_key_name] ~= nil then
			user_paths = setup_opts[path_key_name]
		else
			user_paths = default_paths
		end

		local function do_lazy_load()
			local opts = nil
			if user_paths == nil then
				opts = nil
			else
				local t = type(user_paths)
				if t == "string" then
					opts = { paths = { user_paths } }
				elseif t == "table" then
					opts = { paths = user_paths }
				else
					opts = nil
				end
			end

			pcall(function()
				loader.lazy_load(opts)
			end)
		end
		do_lazy_load()
	end

	-- Call loaders using resolved_path as the default
	load_loader("load_vscode", "luasnip.loaders.from_vscode", "snippets_path", resolved_path)
	load_loader("load_lua", "luasnip.loaders.from_lua", "snippets_path", resolved_path)
	load_loader("load_snipmate", "luasnip.loaders.from_snipmate", "snippets_path", resolved_path)
end

return M

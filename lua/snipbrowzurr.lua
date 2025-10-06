-- lua/plugin/snipbrowzurr.lua
-- Minimal snippet browser for LuaSnip (search & selection improvements)

local M = {}
local api = vim.api

-- Returns a module name or nil
-- safe_require() -> module | nil
local function safe_require(name)
	local ok, mod = pcall(require, name)
	if not ok then
		return nil
	end
	return mod
end

-- Determine the filetype of the current buffer
-- get_filetype() -> string
local function get_filetype()
	local ft = vim.bo.filetype
	if ft and ft ~= "" then
		return ft
	end
	return vim.filetype.match({ buf = 0 }) or "text"
end

-- Returns: flat array of snippet objects (may be empty)
--
-- Take the raw snippet structure returned by luasnip (which can be nested
-- and mixed between dictionary-like tables and lists) and return a flat
-- array of snippet-like tables.
--
-- The function recognizes snippet-like objects by the presence of fields
-- such as `body`, `trigger`, `prefix`, `get_doc`, or `nodes`. It will
-- recursively descend into tables that don't look like snippets.
--
-- Parameters:
-- - raw: (table) arbitrary nested table returned by luasnip.get_snippets
-- - out: (table|nil) optional accumulator used during recursion
--
-- flatten_snippets(raw, out) -> table
local function flatten_snippets(raw, out, visited)
	out = out or {}
	visited = visited or {}
	if type(raw) ~= "table" then
		return out
	end

	-- avoid cycles
	if visited[raw] then
		return out
	end
	visited[raw] = true

	-- If raw itself is a list-like table, recurse into elements
	if vim.islist(raw) then
		for _, v in ipairs(raw) do
			if type(v) == "table" then
				flatten_snippets(v, out, visited)
			end
		end
		return out
	end

	-- If the table itself looks like a snippets: record it
	-- This covers the case where snippet like objects are passed as root
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

  -- Otherwise walk the table fields
	for _, v in pairs(raw) do
		if type(v) == "table" then
			if vim.islist(v) then
				-- recursively process each element so snippet-like
				-- objects nested inside are found
				for _, e in ipairs(v) do
					if type(e) == "table" then
						flatten_snippets(e, out, visited)
					end
				end
			else
				local looks_like_snippet = false
				if v.body or v.trigger or v.prefix or v.get_doc or v.nodes then
					looks_like_snippet = true
				end
				if looks_like_snippet then
					table.insert(out, v)
				else
					flatten_snippets(v, out, visited)
				end
			end
		end
	end
	return out
end

-- Returns: flat array of snippet objects produced by flatten_snippets.
--
-- Collect snippets for the given filetype using luasnip. If luasnip is
-- not available or returns an empty set, an empty table is returned.
--
-- Special handling:
-- - luasnip may return an object with a `.tbl` key. In that case we use
-- `.tbl` as the snippet container before flattening.
--
-- Parameters:
-- - filetype: optional string; if omitted the current buffer's filetype
-- is used (via get_filetype()).
--
-- collect_snippets(filetype?) -> table
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
	return flatten_snippets(raw, {})
end

-- Returns: string label (never nil)
--
-- Produce a short, human-readable label for a snippet. This label is used
-- in the list UI and should be concise. The function prefers fields in the
-- following order: name, description/desc/dscr/desr, trigger/trig, prefix,
-- opts.description. If none of those exist it falls back to `vim.inspect`
-- of the snippet (trimmed) or a placeholder for `nil`.
--
-- Parameters:
-- - sn: snippet table (may be nil)
--
-- snippet_label(snippet) -> string
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

-- Convert a snippet's body into plain text suitable for insertion into a
-- buffer when expansion via LuaSnip fails. Supports several snippet shapes:
-- - body: string -> returned as-is
-- - body: table -> lines joined with "\n"
-- - get_doc: function -> call and use returned string if valid
-- - nodes: table -> `vim.inspect` nodes and join them
-- Fallback: inspect the snippet and return the string representation.
--
-- snippet_body_text(snippet) -> string
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

-- Attempt to expand text as a snippet using LuaSnip extension points.
-- The function tries the following in order, returning true on first
-- successful attempt:
-- 1) ls.lsp_expand(text)
-- 2) parsed = ls.parser.parse_snippet(nil, text, {}); ls.snip_expand(parsed)
--
-- The function uses pcall to avoid throwing on missing or failing
-- implementation details; return `true` only if expansion succeeded.
--
-- try_expand_with_text(ls, text) -> boolean
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

-- Expand the given snippet (or raw text) into the given window's buffer.
-- If `winid` is valid the function will switch to that window prior to
-- expansion and ensure the editor is in insert mode. Expansion attempts
-- are resilient: several strategies are tried via try_expand_with_text.
--
-- If expansion ultimately fails, the function inserts a fallback plain
-- text representation of the snippet (using snippet_body_text) with
-- `nvim_put` and warns the user via `vim.notify`.
--
-- expand_snippet_in_window(winid?, snip_or_text)
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

	-- Fallback: Insert plain text insertion
	local text = snippet_body_text(snip_or_text)
	api.nvim_put(vim.split(text, "\n", { plain = true }), "c", true, true)
	vim.notify("Snippet expansion failed; inserted fallback text", vim.log.levels.WARN)
end

-- Close a window if it is valid. Uses pcall to avoid errors when the
-- window closes concurrently or becomes invalid.
local function safe_close_win(win)
	if win and api.nvim_win_is_valid(win) then
		pcall(api.nvim_win_close, win, true)
	end
end

-- Delete a buffer if it is valid. This is used when cleaning up the
-- temporary search/list buffers created by the plugin.
local function safe_delete_buf(buf)
	if buf and api.nvim_buf_is_valid(buf) then
		pcall(api.nvim_buf_delete, buf, { force = true })
	end
end

-- Perform a simple fuzzy subsequence match: every non-space char of the
-- pattern must appear in the haystack in order. Case-insensitive.
--
-- Examples:
-- fuzzy_match("HelloWorld", "hwd") -> true
-- fuzzy_match("abc", "d") -> false
local function fuzzy_match(hay, pat)
	if not pat or pat == "" then
		return true
	end
	if not hay or hay == "" then
		return false
	end
	hay = hay:lower()
	pat = pat:lower()
	local i = 1
	for p = 1, #pat do
		local c = pat:sub(p, p)
		if c == " " then
		else
			local found = hay:find(c, i, true)
			if not found then
				return false
			end
			i = found + 1
		end
	end
	return true
end


-- Build and show the UI
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

	-- window options
	local orig_win = api.nvim_get_current_win()
	local width = math.min(80, math.max(40, math.floor(vim.o.columns * 0.6)))
	local height = math.min(20, math.max(6, math.floor(vim.o.lines * 0.4)))
	local search_h = 1
	local list_h = math.max(3, height - search_h)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	-- two buffers: search and list
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

	-- namespace for highlights
	local ns = api.nvim_create_namespace("snipbrowzurr")

	local function format_item_display(it, is_selected)
		local trig = it.trigger ~= "" and (" [" .. it.trigger .. "]") or ""
		local label = it.label:gsub("\t", " ")
		local prefix = is_selected and "> " or "  "
		return prefix .. label .. trig
	end

	-- TODO: implement a scroll navigation
	local function render_list()
		local lines = {}
		for i, it in ipairs(filtered) do
			lines[#lines + 1] = format_item_display(it, (i == selected_idx))
		end
		api.nvim_set_option_value("modifiable", true, { buf = list_buf })
		api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
		api.nvim_set_option_value("modifiable", false, { buf = list_buf })

		-- highlights: clear then highlight selected line for clear visual focus
		api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)
		if selected_idx >= 1 and selected_idx <= #filtered then
			-- highlight the entire selected line
			api.nvim_buf_set_extmark(list_buf, ns, selected_idx - 1, 0, { hl_group = "Visual" })
			-- api.nvim_buf_add_highlight(list_buf, ns, "Visual", selected_idx - 1, 0, -1)
		end
		-- Note: do NOT change windows/cursor here (we keep focus in search buffer)
	end

	render_list()

	local function close_popup()
		-- Close windows and delete buffers safely
		safe_close_win(search_win)
		safe_close_win(list_win)
		safe_delete_buf(search_buf)
		safe_delete_buf(list_buf)
		if orig_win and api.nvim_win_is_valid(orig_win) then
			api.nvim_set_current_win(orig_win)
		end
	end

	local function select_current()
		if selected_idx < 1 or selected_idx > #filtered then
			return
		end
		local choice = filtered[selected_idx]
		close_popup()
		if choice then
			expand_snippet_in_window(orig_win, choice.raw)
		end
	end

	local function clamp(v, a, b)
		if v < a then
			return a
		end
		if v > b then
			return b
		end
		return v
	end

	local function change_selection(delta)
		if #filtered == 0 then
			return
		end
		selected_idx = clamp(selected_idx + delta, 1, #filtered)
		render_list()
	end

	local function set_selection(index)
		if #filtered == 0 then
			selected_idx = 0
			render_list()
			return
		end
		selected_idx = clamp(index, 1, #filtered)
		render_list()
	end

  -- Filter the snippet list on each keystroke
	local function do_filter()
		local ok, lines = pcall(api.nvim_buf_get_lines, search_buf, 0, -1, false)
		if not ok then
			return
		end
		local q = (lines and lines[1]) or ""
		q = vim.trim(q)
		if q == "" then
			filtered = filtered
		else
			local tokens = {}
			for token in q:gmatch("%S+") do
				table.insert(tokens, token)
			end
			local newf = {}
			for _, it in ipairs(items) do
				-- CLEAR: filtering only against the "searchable fields":
				-- 1) item.label (human-readable snippet label)
				-- 2) item.trigger (trigger/prefix)
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

		-- after filtering, select first item automatically
		if #filtered > 0 then
			selected_idx = 1
		else
			selected_idx = 0
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

	-- attach to search buffer to get on_lines events and schedule safe updates
	if api.nvim_buf_is_valid(search_buf) then
		api.nvim_buf_attach(search_buf, false, {
			on_lines = function()
				vim.schedule(function()
					do_filter()
				end)
				return false
			end,
		})
	end

	-- Buffer-local mappings for search buffer: keep user in insert mode while allowing navigation & selection
	-- ENTER expands currently selected snippet (works in insert mode)
	vim.keymap.set("i", "<CR>", function()
		-- expand selected and return to normal flow (we will close popup inside select_current)
		select_current()
		-- no need to re-enter insert here because select_current will switch the window to orig and startinsert as needed
	end, { buffer = search_buf, silent = true })

	-- Navigation while in insert mode: Up/Down and Ctrl-k/Ctrl-j
	local nav_fn = function(delta)
		return function()
			change_selection(delta)
			-- re-enter insert so user can keep typing seamlessly
			vim.cmd("startinsert")
			-- pcall(vim.cmd, "startinsert")
		end
	end

	vim.keymap.set("i", "<C-n>", nav_fn(1), { buffer = search_buf, silent = true })
	vim.keymap.set("i", "<C-p>", nav_fn(-1), { buffer = search_buf, silent = true })
	vim.keymap.set("i", "<C-j>", nav_fn(1), { buffer = search_buf, silent = true })
	vim.keymap.set("i", "<C-k>", nav_fn(-1), { buffer = search_buf, silent = true })

	-- Also allow these in normal mode (if user switched modes)
	vim.keymap.set("n", "<Down>", function()
		change_selection(1)
	end, { buffer = search_buf, silent = true })
	vim.keymap.set("n", "<Up>", function()
		change_selection(-1)
	end, { buffer = search_buf, silent = true })

	-- keep existing list-buffer keys usable in case the user focuses it
	vim.keymap.set("n", "j", "j", { buffer = list_buf })
	vim.keymap.set("n", "k", "k", { buffer = list_buf })
	vim.keymap.set("n", "<C-n>", "j", { buffer = list_buf })
	vim.keymap.set("n", "<C-p>", "k", { buffer = list_buf })
	vim.keymap.set("n", "<CR>", function()
		select_current()
	end, { buffer = list_buf, silent = true })

	-- closing
	vim.keymap.set("n", "<Esc>", function()
		close_popup()
	end, { buffer = search_buf, silent = true })
	vim.keymap.set("n", "<Esc>", function()
		close_popup()
	end, { buffer = list_buf, silent = true })

	-- start insert in the search buffer
	api.nvim_set_current_win(search_win)
	vim.cmd("startinsert")
end

function M.show_current()
	M.show({ filetype = get_filetype() })
end

-- Configure the plugin: installs a user command and a keymap, and (by
-- default) attempts to lazy-load VSCode-style snippets via "luasnip.loaders.from_vscode".
--
-- Parameters:
-- - user_opts: table (optional)
-- - keymap: string (default: "<leader>ss") - maps a key to show snippets
function M.setup(user_opts)
	user_opts = user_opts or {}
	local keymap = user_opts.keymap or "<leader>ss"

	local default_path = vim.fn.stdpath("config") .. "/snippets"
	local resolved_path = user_opts.snippets_path ~= nil and user_opts.snippets_path or default_path

	api.nvim_create_user_command("LuaSnipList", function()
		M.show_current()
	end, { desc = "Show LuaSnip snippets for current file" })
	if keymap and keymap ~= "" then
		vim.keymap.set("n", keymap, function()
			M.show_current()
		end, { desc = "Show snippets for current file" })
	end

	-- This function abstracts away repetitive loader logic and loads
	-- multiple types of snippets by hitting appropriate LuaSnip APIs
	local function load_loader(flag_name, loader_module, path_key_name)
		if user_opts[flag_name] == false then
			return
		end
		local ok, loader = pcall(require, loader_module)
		if not ok or type(loader) ~= "table" then
			return
		end
		local user_paths = user_opts[path_key_name]

		local function do_lazy_load()
			local opts = nil
			if user_paths == nil then
				opts = nil
			else
				local t = type(user_paths)
				if t == "string" then
					opts = { paths = { user_paths } }
				elseif t == "table" then
					opts = { paths = { user_paths } }
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

	load_loader("load_vscode", "luasnip.loaders.from_vscode", resolved_path)
	load_loader("load_lua", "luasnip.loaders.from_lua", resolved_path)
	load_loader("load_snipmate", "luasnip.loaders.from_snipmate", resolved_path)
end

return M

-- Telescope-like floating picker for gitlab-ide.nvim
local M = {}

local state = {
	results_win = nil,
	results_buf = nil,
	prompt_win = nil,
	prompt_buf = nil,
	all_items = {},
	filtered = {},
	sel_idx = 1,
	current_item = nil,
	on_select = nil,
	ns_id = vim.api.nvim_create_namespace("gitlab_ide_picker"),
}

--- Close the picker and clean up
local function close_picker()
	vim.cmd("stopinsert")

	local on_select = state.on_select
	state.on_select = nil -- prevent re-entrant calls

	if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
		vim.api.nvim_win_close(state.prompt_win, true)
	end
	if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
		vim.api.nvim_win_close(state.results_win, true)
	end
	if state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) then
		vim.api.nvim_buf_delete(state.prompt_buf, { force = true })
	end
	if state.results_buf and vim.api.nvim_buf_is_valid(state.results_buf) then
		vim.api.nvim_buf_delete(state.results_buf, { force = true })
	end

	state.results_win = nil
	state.results_buf = nil
	state.prompt_win = nil
	state.prompt_buf = nil

	return on_select
end

--- Render the results buffer based on current filtered items and selection
local function render_results()
	local buf = state.results_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local lines = {}
	if #state.filtered == 0 then
		table.insert(lines, "  (no matches)")
	else
		for i, item in ipairs(state.filtered) do
			local prefix = (i == state.sel_idx) and "> " or "  "
			local suffix = (item == state.current_item) and " (current)" or ""
			table.insert(lines, prefix .. item .. suffix)
		end
	end

	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	-- Highlight selected row
	vim.api.nvim_buf_clear_namespace(buf, state.ns_id, 0, -1)
	if #state.filtered > 0 and state.sel_idx >= 1 and state.sel_idx <= #state.filtered then
		vim.api.nvim_buf_add_highlight(buf, state.ns_id, "CursorLine", state.sel_idx - 1, 0, -1)
	end

	-- Scroll results window to keep selection visible
	if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
		local target_row = (#state.filtered == 0) and 1 or state.sel_idx
		vim.api.nvim_win_set_cursor(state.results_win, { target_row, 0 })
	end
end

--- Move selection by delta, clamped to valid range
---@param delta number +1 for down, -1 for up
local function move_selection(delta)
	if #state.filtered == 0 then
		return
	end
	local new_idx = state.sel_idx + delta
	if new_idx < 1 then
		new_idx = 1
	elseif new_idx > #state.filtered then
		new_idx = #state.filtered
	end
	state.sel_idx = new_idx
	render_results()
end

--- Filter items based on query string
---@param query string Search query
local function filter_items(query)
	if query == "" then
		state.filtered = vim.list_slice(state.all_items)
	else
		local q = query:lower()
		state.filtered = {}
		for _, item in ipairs(state.all_items) do
			if item:lower():find(q, 1, true) then
				table.insert(state.filtered, item)
			end
		end
	end
	state.sel_idx = 1
	render_results()
end

--- Confirm the current selection
local function confirm_selection()
	local chosen = nil
	if #state.filtered > 0 and state.sel_idx >= 1 and state.sel_idx <= #state.filtered then
		chosen = state.filtered[state.sel_idx]
	end
	local on_select = close_picker()
	if on_select then
		on_select(chosen)
	end
end

--- Cancel the picker
local function cancel_picker()
	local on_select = close_picker()
	if on_select then
		on_select(nil)
	end
end

--- Open the picker
---@param opts table { items: string[], prompt: string, current_item: string|nil, on_select: function }
function M.open(opts)
	-- Close any existing picker
	if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
		close_picker()
	end

	state.all_items = opts.items or {}
	state.filtered = vim.list_slice(state.all_items)
	state.sel_idx = 1
	state.current_item = opts.current_item
	state.on_select = opts.on_select

	-- Dimensions
	local editor_width = vim.o.columns
	local editor_height = vim.o.lines
	local width = math.max(30, math.floor(editor_width * 0.5))
	local results_height = math.min(#state.all_items, 15)
	results_height = math.max(results_height, 1)
	local prompt_height = 1

	-- Total height = results + prompt + borders (4 rows for borders: 2 per window)
	local total_height = results_height + prompt_height + 4
	local start_col = math.floor((editor_width - width) / 2)
	local start_row = math.floor((editor_height - total_height) / 2)

	-- Results buffer
	state.results_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(state.results_buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(state.results_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(state.results_buf, "swapfile", false)

	-- Results window (top)
	local prompt_text = opts.prompt or "Select"
	state.results_win = vim.api.nvim_open_win(state.results_buf, false, {
		relative = "editor",
		width = width,
		height = results_height,
		col = start_col,
		row = start_row,
		style = "minimal",
		border = "rounded",
		title = " " .. prompt_text .. " ",
		title_pos = "center",
	})
	vim.api.nvim_win_set_option(state.results_win, "cursorline", false)
	vim.api.nvim_win_set_option(state.results_win, "wrap", false)

	-- Prompt buffer
	state.prompt_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(state.prompt_buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(state.prompt_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(state.prompt_buf, "swapfile", false)

	-- Prompt window (below results)
	local prompt_row = start_row + results_height + 2 -- +2 for results border
	state.prompt_win = vim.api.nvim_open_win(state.prompt_buf, true, {
		relative = "editor",
		width = width,
		height = prompt_height,
		col = start_col,
		row = prompt_row,
		style = "minimal",
		border = "rounded",
	})
	vim.api.nvim_win_set_option(state.prompt_win, "wrap", false)

	-- Render initial results
	render_results()

	-- Start in insert mode
	vim.cmd("startinsert")

	-- Set up filtering via buf_attach
	vim.api.nvim_buf_attach(state.prompt_buf, false, {
		on_lines = function()
			vim.schedule(function()
				if not state.prompt_buf or not vim.api.nvim_buf_is_valid(state.prompt_buf) then
					return true -- detach
				end
				local lines = vim.api.nvim_buf_get_lines(state.prompt_buf, 0, 1, false)
				local query = (lines and lines[1]) or ""
				filter_items(query)
			end)
		end,
	})

	-- Keymaps on prompt buffer (insert mode)
	local kopts = { noremap = true, silent = true, buffer = state.prompt_buf }

	-- Navigation
	vim.keymap.set("i", "<C-n>", function()
		move_selection(1)
	end, kopts)
	vim.keymap.set("i", "<C-j>", function()
		move_selection(1)
	end, kopts)
	vim.keymap.set("i", "<Down>", function()
		move_selection(1)
	end, kopts)
	vim.keymap.set("i", "<C-p>", function()
		move_selection(-1)
	end, kopts)
	vim.keymap.set("i", "<C-k>", function()
		move_selection(-1)
	end, kopts)
	vim.keymap.set("i", "<Up>", function()
		move_selection(-1)
	end, kopts)

	-- Confirm
	vim.keymap.set("i", "<CR>", function()
		confirm_selection()
	end, kopts)

	-- Cancel
	vim.keymap.set("i", "<Esc>", function()
		cancel_picker()
	end, kopts)

	-- BufLeave autocmd — close picker if focus leaves prompt
	vim.api.nvim_create_autocmd("BufLeave", {
		buffer = state.prompt_buf,
		once = true,
		callback = function()
			-- Schedule to avoid closing during window transitions
			vim.schedule(function()
				if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
					cancel_picker()
				end
			end)
		end,
	})
end

return M

-- Issues UI for gitlab-ide.nvim
local M = {}
local api = require("gitlab-ide.api")

-- Issue state icons
local issue_icons = {
	opened = " ",
	closed = " ",
}

-- Issue state highlights
local issue_highlights = {
	opened = "DiagnosticOk",
	closed = "DiagnosticError",
}

-- Issues UI state
local state = {
	list_window = nil,
	list_buffer = nil,
	detail_window = nil,
	detail_buffer = nil,
	issues = {},
	api_context = nil,
	refresh_fn = nil,
	current_issue = nil,
}

--- Get icon for an issue
---@param issue table Issue data
---@return string icon
local function get_issue_icon(issue)
	local s = issue.state or "opened"
	return issue_icons[s] or issue_icons.opened
end

--- Get highlight group for an issue
---@param issue table Issue data
---@return string hl_group
local function get_issue_highlight(issue)
	local s = issue.state or "opened"
	return issue_highlights[s] or issue_highlights.opened
end

--- Format labels array into a comma-separated string
---@param labels table Array of label objects or strings
---@return string
local function format_labels(labels)
	if not labels or #labels == 0 then
		return ""
	end
	local names = {}
	for _, label in ipairs(labels) do
		if type(label) == "string" then
			table.insert(names, label)
		elseif label.name then
			table.insert(names, label.name)
		end
	end
	return table.concat(names, ", ")
end

--- Close the detail view
local function close_detail_view()
	if state.detail_window and vim.api.nvim_win_is_valid(state.detail_window) then
		vim.api.nvim_win_close(state.detail_window, true)
	end
	if state.detail_buffer and vim.api.nvim_buf_is_valid(state.detail_buffer) then
		vim.api.nvim_buf_delete(state.detail_buffer, { force = true })
	end
	state.detail_window = nil
	state.detail_buffer = nil
	state.current_issue = nil
end

--- Close the list view
local function close_list_view()
	if state.list_window and vim.api.nvim_win_is_valid(state.list_window) then
		vim.api.nvim_win_close(state.list_window, true)
	end
	if state.list_buffer and vim.api.nvim_buf_is_valid(state.list_buffer) then
		vim.api.nvim_buf_delete(state.list_buffer, { force = true })
	end
	state.list_window = nil
	state.list_buffer = nil
end

--- Close all issue views
local function close_all()
	close_detail_view()
	close_list_view()
	state.issues = {}
	state.api_context = nil
	state.refresh_fn = nil
end

--- Get the issue under cursor in the list view
---@return table|nil issue
local function get_issue_under_cursor()
	if not state.list_window or not vim.api.nvim_win_is_valid(state.list_window) then
		return nil
	end
	local cursor_row = vim.api.nvim_win_get_cursor(state.list_window)[1]
	-- Row 1: header, Row 2: separator, Rows 3+: issues
	local issue_index = cursor_row - 2
	if issue_index < 1 or issue_index > #state.issues then
		return nil
	end
	return state.issues[issue_index]
end

--- Render the issues list buffer
---@param buf number Buffer ID
local function render_list(buf)
	local lines = {}
	local highlights_to_apply = {}

	local header = string.format("  %-6s │ %-50s │ %s", "IID", "Title", "Labels")
	table.insert(lines, header)
	table.insert(lines, string.rep("─", #header + 10))

	for _, issue in ipairs(state.issues) do
		local icon = get_issue_icon(issue)
		local labels_str = format_labels(issue.labels)
		local title = issue.title or ""
		if #title > 50 then
			title = title:sub(1, 47) .. "..."
		end
		local line = string.format("  #%-5s │ %s %-48s │ %s", issue.iid, icon, title, labels_str)
		table.insert(lines, line)

		table.insert(highlights_to_apply, {
			line = #lines - 1,
			col_start = 10,
			col_end = 10 + #icon,
			hl_group = get_issue_highlight(issue),
		})
	end

	if #state.issues == 0 then
		table.insert(lines, "")
		table.insert(lines, "  No issues assigned to you in this project.")
	end

	table.insert(lines, "")
	local hint = " ⏎:detail o:browser r:refresh q/Esc:close"
	table.insert(lines, hint)
	table.insert(highlights_to_apply, {
		line = #lines - 1,
		col_start = 0,
		col_end = #hint,
		hl_group = "Comment",
	})

	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	local ns_id = vim.api.nvim_create_namespace("gitlab_ide_issues")
	vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
	for _, hl in ipairs(highlights_to_apply) do
		vim.api.nvim_buf_add_highlight(buf, ns_id, hl.hl_group, hl.line, hl.col_start, hl.col_end)
	end
end

--- Render the issue detail buffer
---@param buf number Buffer ID
---@param issue table Full issue data
local function render_detail(buf, issue)
	local lines = {}
	local highlights_to_apply = {}
	local ns_id = vim.api.nvim_create_namespace("gitlab_ide_issue_detail")

	local icon = get_issue_icon(issue)
	local title_line = string.format("  %s #%s  %s  [%s]", icon, issue.iid, issue.title or "", issue.state or "")
	table.insert(lines, title_line)
	table.insert(highlights_to_apply, {
		line = 0,
		col_start = 2,
		col_end = 2 + #icon,
		hl_group = get_issue_highlight(issue),
	})
	table.insert(lines, string.rep("═", 80))
	table.insert(lines, "")

	-- Assignees
	local assignees = issue.assignees or {}
	if #assignees > 0 then
		local names = {}
		for _, a in ipairs(assignees) do
			table.insert(names, string.format("%s (@%s)", a.name, a.username))
		end
		table.insert(lines, "  Assignees:  " .. table.concat(names, ", "))
	end

	-- Labels
	local labels_str = format_labels(issue.labels)
	if labels_str ~= "" then
		table.insert(lines, "  Labels:     " .. labels_str)
	end

	-- Milestone
	if issue.milestone and type(issue.milestone) == "table" and issue.milestone.title then
		table.insert(lines, "  Milestone:  " .. issue.milestone.title)
	end

	-- Dates
	local created = issue.created_at and issue.created_at:match("^[^T]+") or "unknown"
	local updated = issue.updated_at and issue.updated_at:match("^[^T]+") or "unknown"
	table.insert(lines, "  Created:    " .. created)
	table.insert(lines, "  Updated:    " .. updated)

	-- Description
	table.insert(lines, "")
	table.insert(lines, string.rep("─", 80))
	table.insert(lines, "  Description:")
	table.insert(lines, string.rep("─", 80))
	table.insert(lines, "")

	local description = issue.description or "(no description)"
	for _, line in ipairs(vim.split(description, "\n", { trimempty = false })) do
		table.insert(lines, "  " .. line)
	end

	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
	for _, hl in ipairs(highlights_to_apply) do
		vim.api.nvim_buf_add_highlight(buf, ns_id, hl.hl_group, hl.line, hl.col_start, hl.col_end)
	end
end

--- Set up keymaps for the issues detail view
---@param buf number Buffer ID
local function setup_detail_keymaps(buf)
	local opts = { noremap = true, silent = true, buffer = buf }

	-- Back to list
	local function back_to_list()
		close_detail_view()
		if state.list_buffer and vim.api.nvim_buf_is_valid(state.list_buffer) then
			if state.list_window and vim.api.nvim_win_is_valid(state.list_window) then
				vim.api.nvim_set_current_win(state.list_window)
			end
		end
	end
	vim.keymap.set("n", "q", back_to_list, opts)
	vim.keymap.set("n", "<BS>", back_to_list, opts)

	-- Close all
	vim.keymap.set("n", "<Esc>", close_all, opts)

	-- Open in browser
	vim.keymap.set("n", "o", function()
		local issue = state.current_issue
		if issue and issue.web_url then
			vim.ui.open(issue.web_url)
		end
	end, opts)

	-- Refresh detail
	vim.keymap.set("n", "r", function()
		local issue = state.current_issue
		if not issue or not state.api_context then
			return
		end
		local ctx = state.api_context
		api.fetch_issue_detail(ctx.gitlab_url, ctx.token, ctx.project_path, issue.iid, function(err, detail)
			if err then
				vim.notify("Refresh failed: " .. err, vim.log.levels.ERROR)
				return
			end
			state.current_issue = detail
			if state.detail_buffer and vim.api.nvim_buf_is_valid(state.detail_buffer) then
				render_detail(state.detail_buffer, detail)
			end
		end)
	end, opts)
end

--- Open the detail view for an issue
---@param issue table Issue data (from list)
local function open_detail_view(issue)
	if not state.api_context then
		vim.notify("API context not available", vim.log.levels.ERROR)
		return
	end

	local ctx = state.api_context
	api.fetch_issue_detail(ctx.gitlab_url, ctx.token, ctx.project_path, issue.iid, function(err, detail)
		if err then
			vim.notify("Failed to fetch issue detail: " .. err, vim.log.levels.ERROR)
			return
		end

		state.current_issue = detail

		local editor_width = vim.o.columns
		local editor_height = vim.o.lines
		local width = math.floor(editor_width * 0.85)
		local height = math.floor(editor_height * 0.85)
		local col = math.floor((editor_width - width) / 2)
		local row = math.floor((editor_height - height) / 2)

		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
		vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
		vim.api.nvim_buf_set_option(buf, "swapfile", false)

		local icon = get_issue_icon(detail)
		local title = string.format(" %s #%s %s ", icon, detail.iid, detail.title or "")
		if #title > width - 4 then
			title = title:sub(1, width - 7) .. "... "
		end

		local win = vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			width = width,
			height = height,
			col = col,
			row = row,
			style = "minimal",
			border = "rounded",
			title = title,
			title_pos = "center",
			footer = " q/⌫:back o:browser r:refresh Esc:close ",
			footer_pos = "center",
		})

		vim.api.nvim_win_set_option(win, "wrap", true)

		state.detail_window = win
		state.detail_buffer = buf

		render_detail(buf, detail)
		setup_detail_keymaps(buf)
	end)
end

--- Set up keymaps for the issues list view
---@param buf number Buffer ID
local function setup_list_keymaps(buf)
	local opts = { noremap = true, silent = true, buffer = buf }

	vim.keymap.set("n", "q", close_all, opts)
	vim.keymap.set("n", "<Esc>", close_all, opts)

	vim.keymap.set("n", "r", function()
		if state.refresh_fn then
			state.refresh_fn()
		end
	end, opts)

	vim.keymap.set("n", "<CR>", function()
		local issue = get_issue_under_cursor()
		if not issue then
			vim.notify("No issue under cursor", vim.log.levels.WARN)
			return
		end
		open_detail_view(issue)
	end, opts)

	vim.keymap.set("n", "o", function()
		local issue = get_issue_under_cursor()
		if not issue or not issue.web_url then
			vim.notify("No issue under cursor", vim.log.levels.WARN)
			return
		end
		vim.ui.open(issue.web_url)
	end, opts)
end

--- Open the issues list view
---@param issues table List of issue data
---@param refresh_fn function Function to refresh the list
---@param api_context table API context { gitlab_url, token, project_path }
function M.open_list(issues, refresh_fn, api_context)
	close_all()

	state.issues = issues
	state.refresh_fn = refresh_fn
	state.api_context = api_context

	local editor_width = vim.o.columns
	local editor_height = vim.o.lines
	local width = math.floor(editor_width * 0.7)
	local height = math.floor(editor_height * 0.6)
	local col = math.floor((editor_width - width) / 2)
	local row = math.floor((editor_height - height) / 2)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "swapfile", false)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = col,
		row = row,
		style = "minimal",
		border = "rounded",
		title = " Issues ",
		title_pos = "center",
		footer = " ⏎:detail o:browser r:refresh q:close ",
		footer_pos = "center",
	})

	vim.api.nvim_win_set_option(win, "cursorline", true)
	vim.api.nvim_win_set_option(win, "wrap", false)

	state.list_window = win
	state.list_buffer = buf

	render_list(buf)
	setup_list_keymaps(buf)

	if #issues > 0 then
		vim.api.nvim_win_set_cursor(win, { 3, 0 })
	end
end

return M

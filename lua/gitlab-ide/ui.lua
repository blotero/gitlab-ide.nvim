-- Multi-window UI orchestrator for gitlab-ide.nvim
local M = {}
local icons = require("gitlab-ide.ui.icons")
local log = require("gitlab-ide.ui.log")
local pipeline = require("gitlab-ide.ui.pipeline")

-- UI state
local state = {
	windows = {}, -- List of window IDs
	buffers = {}, -- List of buffer IDs
	current_stage = 1, -- Currently focused stage index
	pipeline = nil, -- Current pipeline data
	refresh_fn = nil, -- Function to refresh data
	api_context = nil, -- { gitlab_url, token, project_path }
	on_switch_branch = nil, -- callback to open branch picker
	view = "pipeline", -- "pipeline" or "log"
	log_state = nil, -- { window, buffer, job, timer }
}

--- Close all UI windows and clean up
function M.close()
	-- Clean up log state if active
	if state.log_state then
		if state.log_state.timer then
			state.log_state.timer:stop()
			state.log_state.timer:close()
			state.log_state.timer = nil
		end
		if state.log_state.window and vim.api.nvim_win_is_valid(state.log_state.window) then
			vim.api.nvim_win_close(state.log_state.window, true)
		end
		if state.log_state.buffer and vim.api.nvim_buf_is_valid(state.log_state.buffer) then
			vim.api.nvim_buf_delete(state.log_state.buffer, { force = true })
		end
		state.log_state = nil
	end

	pipeline.close_windows(state)

	state.current_stage = 1
	state.pipeline = nil
	state.view = "pipeline"
end

--- Open the pipeline UI
---@param pipeline_data table Pipeline data from API
---@param refresh_fn function|nil Optional function to refresh data
---@param api_context table|nil API context { gitlab_url, token, project_path }
---@param on_switch_branch function|nil Callback to open branch picker
function M.open(pipeline_data, refresh_fn, api_context, on_switch_branch)
	-- Close any existing UI
	M.close()

	state.pipeline = pipeline_data
	state.refresh_fn = refresh_fn
	state.api_context = api_context or state.api_context
	state.on_switch_branch = on_switch_branch or state.on_switch_branch
	state.view = "pipeline"

	local stages = pipeline_data.stages and pipeline_data.stages.nodes or {}
	if #stages == 0 then
		vim.notify("No stages found in pipeline", vim.log.levels.WARN)
		return
	end

	-- Calculate dimensions
	local editor_width = vim.o.columns
	local editor_height = vim.o.lines

	local total_width = math.floor(editor_width * 0.8)
	local total_height = math.floor(editor_height * 0.7)

	local num_stages = #stages
	local stage_width = math.floor((total_width - (num_stages - 1) * 2) / num_stages)
	local stage_height = total_height - 2

	-- Calculate starting position (centered)
	local start_col = math.floor((editor_width - total_width) / 2)
	local start_row = math.floor((editor_height - total_height) / 2)

	-- Callbacks for sub-modules
	local callbacks = {
		close = function()
			M.close()
		end,
		open_log = function(job)
			log.open(job, state, function()
				pipeline.close_windows(state)
			end, function()
				M.close()
			end, function()
				if state.pipeline then
					M.open(state.pipeline, state.refresh_fn, state.api_context)
				end
			end)
		end,
	}

	-- Create windows for each stage
	for i, stage in ipairs(stages) do
		local col = start_col + (i - 1) * (stage_width + 2)
		local win, buf = pipeline.create_stage_window(stage, col, stage_width, stage_height, start_row, state, callbacks)
		table.insert(state.windows, win)
		table.insert(state.buffers, buf)
	end

	-- Focus first stage
	state.current_stage = 1
	if state.windows[1] and vim.api.nvim_win_is_valid(state.windows[1]) then
		vim.api.nvim_set_current_win(state.windows[1])
	end

	-- Show pipeline info in statusline area
	local status_icon = icons.get_icon(pipeline_data.status)
	local created = pipeline_data.createdAt and pipeline_data.createdAt:match("^[^T]+") or "unknown"
	vim.notify(
		string.format("Pipeline #%s %s %s (created: %s)", pipeline_data.iid, status_icon, pipeline_data.status, created),
		vim.log.levels.INFO
	)
end

--- Refresh the UI with new pipeline data
---@param pipeline_data table Pipeline data from API
function M.refresh(pipeline_data)
	if #state.windows == 0 then
		M.open(pipeline_data, state.refresh_fn, state.api_context)
		return
	end

	state.pipeline = pipeline_data
	local stages = pipeline_data.stages and pipeline_data.stages.nodes or {}

	-- Re-render existing buffers
	for i, buf in ipairs(state.buffers) do
		if vim.api.nvim_buf_is_valid(buf) and stages[i] then
			pipeline.render_stage(buf, stages[i])
		end
	end

	-- Show updated status
	local status_icon = icons.get_icon(pipeline_data.status)
	vim.notify(
		string.format("Pipeline #%s %s %s (refreshed)", pipeline_data.iid, status_icon, pipeline_data.status),
		vim.log.levels.INFO
	)
end

return M

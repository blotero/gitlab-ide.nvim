-- gitlab-ide.nvim - GitLab CI/CD pipeline status in Neovim
-- Entry point module
local M = {}

local config = require("gitlab-ide.config")
local git = require("gitlab-ide.git")
local api = require("gitlab-ide.api")
local ui = require("gitlab-ide.ui")

--- Setup the plugin with user configuration
---@param opts table|nil User configuration options
function M.setup(opts)
	config.setup(opts)
end

--- Show an error message to the user
---@param msg string Error message
local function show_error(msg)
	vim.notify("gitlab-ide: " .. msg, vim.log.levels.ERROR)
end

--- Build the API context from git/config resolution chain
---@param callback function Callback function(api_context) where api_context = { gitlab_url, token, project_path }
local function build_api_context(callback)
	-- Get remote URL
	local remote = config.get_remote()
	local remote_url, remote_err = git.get_remote_url(remote)
	if not remote_url then
		show_error(remote_err or "Could not get remote URL")
		return
	end

	-- Parse project path
	local project_path, path_err = git.get_project_path(remote_url)
	if not project_path then
		show_error(path_err or "Could not parse project path from remote URL")
		return
	end

	-- Get GitLab URL
	local gitlab_url, url_err = git.get_gitlab_url(remote_url, config.get_gitlab_url())
	if not gitlab_url then
		show_error(url_err or "Could not determine GitLab URL")
		return
	end

	-- Get token
	local token = config.get_token()
	if not token then
		show_error(
			"No GitLab token found. Set GITLAB_TOKEN or GITLAB_PAT environment variable, or configure token in setup()"
		)
		return
	end

	callback({
		gitlab_url = gitlab_url,
		token = token,
		project_path = project_path,
	})
end

--- Open the pipeline view for the current repository and branch
function M.open()
	-- Get current branch
	local branch, branch_err = git.get_current_branch()
	if not branch then
		show_error(branch_err or "Could not determine current branch")
		return
	end

	build_api_context(function(api_context)
		-- Show loading message
		vim.notify(
			"Fetching pipeline for " .. api_context.project_path .. " @ " .. branch .. "...",
			vim.log.levels.INFO
		)

		-- Create refresh function
		local function refresh()
			api.fetch_pipeline(
				api_context.gitlab_url,
				api_context.token,
				api_context.project_path,
				branch,
				function(err, pipeline)
					if err then
						show_error(err)
						return
					end
					ui.refresh(pipeline)
				end
			)
		end

		-- Fetch pipeline data
		api.fetch_pipeline(
			api_context.gitlab_url,
			api_context.token,
			api_context.project_path,
			branch,
			function(err, pipeline)
				if err then
					show_error(err)
					return
				end

				-- Open UI with pipeline data
				ui.open(pipeline, refresh, api_context)
			end
		)
	end)
end

--- Close the pipeline view
function M.close()
	ui.close()
end

--- Open the merge requests list view
function M.open_merge_requests()
	build_api_context(function(api_context)
		vim.notify("Fetching merge requests for " .. api_context.project_path .. "...", vim.log.levels.INFO)

		local mr = require("gitlab-ide.mr")

		local function refresh()
			api.fetch_merge_requests(
				api_context.gitlab_url,
				api_context.token,
				api_context.project_path,
				function(err, merge_requests)
					if err then
						show_error(err)
						return
					end
					mr.open_list(merge_requests, refresh, api_context)
				end
			)
		end

		api.fetch_merge_requests(
			api_context.gitlab_url,
			api_context.token,
			api_context.project_path,
			function(err, merge_requests)
				if err then
					show_error(err)
					return
				end
				mr.open_list(merge_requests, refresh, api_context)
			end
		)
	end)
end

return M

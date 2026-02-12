# gitlab-pipeline.nvim

A Neovim plugin for viewing GitLab CI/CD pipeline status in a multi-column floating window interface.

## Look and feel

<img width="2448" height="1290" alt="image" src="https://github.com/user-attachments/assets/a86bd6dd-3c74-4ac4-b192-f93f1a433bd3" />


## Requirements

- Neovim 0.10+ (for `vim.system()` support)
- `curl` command available in PATH
- GitLab personal access token with `api` scope (for job actions) or `read_api` (read-only)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "your-username/gitlab-pipeline.nvim",
  config = function()
    require("gitlab-pipeline").setup({})
  end,
}
```

Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  "your-username/gitlab-pipeline.nvim",
  config = function()
    require("gitlab-pipeline").setup({})
  end,
}
```

## Configuration

### GitLab Token

Set your GitLab token using one of these methods (in order of priority):

1. Environment variable `GITLAB_TOKEN`
2. Environment variable `GITLAB_PAT`
3. Configuration option `token`

```lua
require("gitlab-pipeline").setup({
  -- Optional: specify token directly (not recommended, use env vars instead)
  -- token = "your-gitlab-token",

  -- Optional: specify which git remote to use (default: "origin")
  remote = "origin",

  -- Optional: override GitLab URL (auto-detected from remote by default)
  -- gitlab_url = "https://gitlab.example.com",
})
```

## Usage

Open a GitLab repository in Neovim and run:

```vim
:GitlabPipeline
```

This opens a multi-column floating window showing the pipeline for your current branch. Navigate to any job and press `Enter` to view its log, or use action keys to cancel/retry jobs directly from the UI.

### Pipeline View Keybindings

| Key | Action |
|-----|--------|
| `h` | Move to previous stage column |
| `l` | Move to next stage column |
| `j` / `k` | Navigate jobs within stage (native Vim motion) |
| `Enter` | Open job log (drill-down) |
| `c` | Cancel job under cursor (with confirmation) |
| `x` | Retry job under cursor |
| `C` | Cancel entire pipeline (with confirmation) |
| `X` | Retry failed jobs in pipeline |
| `r` | Refresh pipeline data |
| `q` / `Esc` | Close pipeline view |

### Log View Keybindings

| Key | Action |
|-----|--------|
| `q` / `Backspace` | Back to pipeline view |
| `Esc` | Close everything |
| `r` | Refresh log |
| `j` / `k` / `Ctrl-d` / `Ctrl-u` / `G` / `gg` | Scroll (native Vim motions) |

Logs for running/pending jobs auto-refresh every 5 seconds.

### Status Icons

| Status | Icon |
|--------|------|
| Success | ✓ |
| Failed | ✗ |
| Running | ● |
| Pending | ○ |
| Skipped | ⊘ |
| Canceled | ⊘ |
| Manual | ▶ |

## License

MIT

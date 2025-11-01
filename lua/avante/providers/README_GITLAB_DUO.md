# GitLab Duo Agentic Platform Provider for Avante.nvim

This provider integrates GitLab Duo's Agentic Platform with Avante.nvim through the GitLab Language Server.

## Prerequisites

1. **GitLab Language Server (gitlab-lsp)**: Must be installed and configured in your Neovim setup
2. **GitLab Account**: With access to GitLab Duo features
3. **GitLab Token**: Configured as `GITLAB_TOKEN` environment variable
4. **Docker** (Optional): Can be enabled for advanced workflow execution (see [Docker Setup](#docker-setup))

## Installation

### 1. Install gitlab-lsp

Follow the [GitLab Language Server installation guide](https://gitlab.com/gitlab-org/editor-extensions/gitlab-lsp).

### 2. Configure gitlab-lsp in Neovim

Add the following to your Neovim configuration:

```lua
require('lspconfig').gitlab_lsp.setup({
  cmd = { "gitlab-lsp", "--stdio" },
  settings = {
    gitlab = {
      baseUrl = "https://gitlab.com", -- or your GitLab instance URL
      token = vim.env.GITLAB_TOKEN,   -- or use another method to provide the token
    },
  },
})
```

### 3. Configure Avante.nvim with GitLab Duo

```lua
require('avante').setup({
  provider = "gitlab_duo",
  providers = {
    gitlab_duo = {
      model = "claude-3-5-sonnet", -- or another supported model
      project_id = "your-project-id", -- optional
      namespace_id = "your-namespace-id", -- optional
      use_docker = false, -- optional, default is false. Set to true to enable Docker support
    },
  },
})
```

## Configuration Options

### `model` (string)

The AI model to use for the workflow. Default: `"claude-3-5-sonnet"`

Supported models depend on your GitLab instance configuration.

### `project_id` (string, optional)

The GitLab project ID (numeric) to associate with the workflow. This provides project-specific context to the AI agent.

**Auto-detection**: If not specified, the provider will automatically:
1. Parse the git remote URL from your current repository
2. Extract the namespace/project path (e.g., `"gitlab-org/gitlab"`)
3. Query the GitLab API to get the numeric project ID
4. Use that ID in the workflow metadata

**Manual configuration**: You can explicitly set the numeric project ID:
```lua
providers = {
  gitlab_duo = {
    project_id = "278964", -- numeric ID
  },
}
```

**Note**: Auto-detection requires:
- You're in a GitLab repository with a remote URL
- The gitlab-lsp client has a valid token and base URL configured

### `namespace_id` (string, optional)

The GitLab namespace ID (numeric) to use for the workflow. This can be a group or user namespace.

**Auto-detection**: Like `project_id`, this is automatically detected from the GitLab API response when querying the project information.

**Note**: This is typically only needed if you want to override the namespace detected from the API.

### `use_docker` (boolean, optional)

Enable Docker support for advanced workflow execution. Default: `false`

When enabled, the provider will:
- Auto-detect Docker socket path on your system
- Configure GitLab LSP to use Docker for workflow execution
- Enable advanced workflow features that require Docker

**Note**: Docker is disabled by default. Most basic workflows work without Docker. Enable it only if you need advanced features like:
- Complex multi-step workflows
- Tool execution in isolated environments
- Code generation and testing

To enable Docker:
```lua
providers = {
  gitlab_duo = {
    use_docker = true,
  },
}
```

### `timeout` (number)

Request timeout in milliseconds. Default: `60000` (60 seconds)

Workflows can take longer than typical API requests, so a higher timeout is recommended.

## Usage

Once configured, use Avante.nvim as normal:

1. Open a file in Neovim
2. Select text (optional)
3. Run `:AvanteAsk` or use your configured keybinding
4. Enter your prompt

The GitLab Duo agent will:
- Analyze your code and context
- Execute tools as needed (with approval)
- Stream responses back to Avante
- Handle multi-step workflows automatically

## Features

### Automatic Context Integration

The provider automatically sends your current buffer content as context to the agent, including:
- File path
- File content
- Selected text (if any)

### Tool Approval

When the agent needs to execute tools (like running commands or modifying files), it will request approval. Currently, the provider auto-approves tool executions for a smoother experience.

To change this behavior, modify the `handle_tool_approval` function in `gitlab_duo.lua`.

### Command Execution

The agent can execute commands in your terminal through the LSP protocol. Commands are run using Neovim's job API.

### Streaming Responses

Responses from the GitLab Duo agent are streamed in real-time, providing immediate feedback as the agent works.

## Docker Setup (Optional)

Docker support is **optional** and **disabled by default**. The provider works without Docker for most basic workflows.

To enable Docker support, set `use_docker = true` in your provider configuration. When enabled, the provider automatically detects Docker socket paths on macOS and Linux.

### Automatic Detection

The provider automatically checks these locations:

**macOS:**
- `~/.colima/default/docker.sock` (Colima)
- `~/.rd/docker.sock` (Rancher Desktop)
- `~/.docker/run/docker.sock` (Docker Desktop)
- `/var/run/docker.sock` (Standard)

**Linux:**
- `/var/run/docker.sock` (Standard)
- `~/.docker/desktop/docker.sock` (Docker Desktop)

### Manual Configuration

If auto-detection doesn't work, set the Docker socket path manually:

```bash
export GITLAB_DOCKER_SOCKET="/path/to/docker.sock"
```

**Common paths:**
```bash
# Colima (macOS)
export GITLAB_DOCKER_SOCKET="$HOME/.colima/default/docker.sock"

# Rancher Desktop (macOS)
export GITLAB_DOCKER_SOCKET="$HOME/.rd/docker.sock"

# Docker Desktop (macOS)
export GITLAB_DOCKER_SOCKET="$HOME/.docker/run/docker.sock"

# Standard Docker (Linux)
export GITLAB_DOCKER_SOCKET="/var/run/docker.sock"
```

### Installing Docker

**macOS (Colima - Recommended):**
```bash
brew install colima docker
colima start
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt-get install docker.io
sudo systemctl start docker
sudo usermod -aG docker $USER
```

For detailed Docker setup instructions, see [DOCKER_SETUP.md](DOCKER_SETUP.md).

### Docker Not Available

If Docker is not available, you'll see a warning:
```
Docker socket not found. Workflow may have limited functionality.
```

**What works without Docker:**
- Basic chat interactions
- Code explanations
- Simple suggestions

**What requires Docker:**
- Complex workflows
- Tool execution
- Code generation and testing

## Troubleshooting

### "Docker socket not configured"

This warning appears when `use_docker = true` but the provider couldn't find Docker. To fix:

1. **Disable Docker** (recommended if you don't need it):
   ```lua
   providers = {
     gitlab_duo = {
       use_docker = false, -- or simply omit this line
     },
   }
   ```

2. **Or install and configure Docker** (if you need Docker features):
   - **Install Docker** (see [Docker Setup](#docker-setup))
   - **Start Docker:**
     ```bash
     # Colima
     colima start

     # Standard Docker
     sudo systemctl start docker
     ```
   - **Verify Docker is running:**
     ```bash
     docker ps
     ```
   - **Set Docker socket path manually** if auto-detection fails:
     ```bash
     export GITLAB_DOCKER_SOCKET="/path/to/docker.sock"
     ```
   - **Restart Neovim** to pick up the environment variable

### "GitLab LSP client not found"

Ensure gitlab-lsp is:
1. Installed correctly
2. Running (check `:LspInfo`)
3. Attached to the current buffer

### \"Duo Agent Platform feature is not enabled\"

This error typically means the workflow request is missing valid project context. To fix:

1. **Ensure you're in a GitLab repository**: The provider auto-detects the project from your git remote URL
   ```bash
   git remote -v
   ```
   Should show a GitLab URL (e.g., `https://gitlab.com/namespace/project.git` or `git@gitlab.com:namespace/project.git`)

2. **Manually specify project_id**: If auto-detection doesn't work, set it explicitly in your config:
   ```lua
   providers = {
     gitlab_duo = {
       project_id = "gitlab-org/gitlab", -- or numeric ID like "278964"
     },
   }
   ```

3. **Check GitLab Duo is enabled**: Ensure your GitLab instance and project have Duo features enabled

4. **Enable debug mode** to see what's being sent:
   ```lua
   require('avante').setup({
     debug = true,
     provider = "gitlab_duo",
   })
   ```
   Then check `:messages` for debug output showing the detected project

### "Workflow failed to start"

Check:
1. Your GitLab token has the necessary permissions
2. Your GitLab instance supports Duo workflows
3. The gitlab-lsp logs for errors (enable LSP logging in Neovim)

### Workflow hangs or times out

- Increase the `timeout` value in the provider configuration
- Check network connectivity to your GitLab instance
- Review gitlab-lsp logs for connection issues

## Advanced Configuration

### Custom Tool Approval

To implement custom tool approval logic:

```lua
-- In your Neovim config, after requiring avante
local gitlab_duo = require('avante.providers.gitlab_duo')

-- Override the approval handler
gitlab_duo.handle_tool_approval = function(workflow_id, chat_log)
  -- Find the approval request
  local approval_request = nil
  for i = #chat_log, 1, -1 do
    if chat_log[i].message_type == 'request' then
      approval_request = chat_log[i]
      break
    end
  end

  if not approval_request or not approval_request.tool_info then return end

  local tool_name = approval_request.tool_info.name

  -- Show approval UI (example using vim.ui.select)
  vim.ui.select(
    { 'Approve Once', 'Approve for Session', 'Reject' },
    { prompt = 'Tool: ' .. tool_name },
    function(choice)
      local client = gitlab_duo.get_gitlab_client()
      if not client then return end

      if choice == 'Reject' then
        client.notify('$/gitlab/startWorkflow', {
          goal = '',
          existingWorkflowId = workflow_id,
          toolApproval = {
            userApproved = false,
            message = 'User rejected the tool call',
          },
        })
      else
        client.notify('$/gitlab/startWorkflow', {
          goal = '',
          existingWorkflowId = workflow_id,
          toolApproval = {
            userApproved = true,
            toolName = tool_name,
            type = choice == 'Approve Once' and 'approve_once' or 'approve-for-session',
          },
        })
      end
    end
  )
end
```

## Architecture

The GitLab Duo provider communicates with the GitLab Language Server using custom LSP notifications:

1. **Client → Server**: `$/gitlab/startWorkflow` - Initiates a new workflow
2. **Server → Client**: `$/gitlab/workflowMessage` - Streams workflow updates
3. **Client → Server**: `$/gitlab/sendWorkflowEvent` - Sends user responses
4. **Server → Client**: `$/gitlab/runCommand` - Requests command execution

For more details, see `prompt.md` in the repository root.

## Contributing

Contributions are welcome! Please refer to the main Avante.nvim contribution guidelines.

## License

This provider is part of Avante.nvim and follows the same license.


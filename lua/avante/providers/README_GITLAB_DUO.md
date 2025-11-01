# GitLab Duo Agentic Platform Provider for Avante.nvim

This provider integrates GitLab Duo's Agentic Platform with Avante.nvim through the GitLab Language Server.

## Prerequisites

1. **GitLab Language Server (gitlab-lsp)**: Must be installed and configured in your Neovim setup
2. **GitLab Account**: With access to GitLab Duo features
3. **GitLab Token**: Configured in gitlab-lsp with appropriate permissions

## Installation

### 1. Install gitlab-lsp

Follow the [GitLab Language Server installation guide](https://gitlab.com/gitlab-org/editor-extensions/gitlab-lsp).

### 2. Configure gitlab-lsp in Neovim

Add the following to your Neovim configuration:

```lua
require('lspconfig').gitlab_lsp.setup({
  cmd = { "gitlab_lsp", "--stdio" },
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
    },
  },
})
```

## Configuration Options

### `model` (string)

The AI model to use for the workflow. Default: `"claude-3-5-sonnet"`

Supported models depend on your GitLab instance configuration.

### `project_id` (string, optional)

The GitLab project ID to associate with the workflow. This provides project-specific context to the AI agent.

### `namespace_id` (string, optional)

The GitLab namespace ID to use for the workflow. This can be a group or user namespace.

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

## Troubleshooting

### "GitLab LSP client not found"

Ensure gitlab-lsp is:
1. Installed correctly
2. Running (check `:LspInfo`)
3. Attached to the current buffer

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


# GitLab Duo Agentic Platform Implementation for Avante.nvim

This document describes the complete implementation of the GitLab Duo Agentic Platform provider for Avante.nvim based on the specification in `prompt.md`.

## Overview

The GitLab Duo provider integrates the GitLab Duo Agentic Platform with Avante.nvim through the GitLab Language Server Protocol (LSP). This implementation provides full workflow management, including:

- Workflow lifecycle management (start, stop, pause, resume)
- Real-time workflow status updates via LSP notifications
- Interactive user approvals (tools, plans, input requests)
- Automatic project detection from git repositories
- Comprehensive error handling with status codes
- Command execution support

## Architecture

```
┌─────────────────┐         LSP Notifications        ┌──────────────────┐
│  Avante.nvim    │◄──────────────────────────────►│  gitlab-lsp      │
│  (Lua Client)   │                                  │  (Node.js)       │
└─────────────────┘                                  └──────────────────┘
                                                              │
                                                              │ gRPC/WebSocket
                                                              ▼
                                                     ┌──────────────────┐
                                                     │  GitLab Backend  │
                                                     │  (Duo Workflow)  │
                                                     └──────────────────┘
```

## Implementation Features

### ✅ Implemented Features

1. **Workflow Management**
   - `M.send_workflow_event()` - Send workflow events (stop, pause, resume, message)
   - `M.stop_workflow()` - Stop an active workflow
   - `M.pause_workflow()` - Pause an active workflow
   - `M.resume_workflow()` - Resume a paused workflow
   - `M.send_user_message()` - Send user messages to workflows

2. **User Interaction Flows**
   - `M.handle_tool_approval()` - Interactive tool approval with user prompts
   - `M.handle_input_required()` - Handle INPUT_REQUIRED status with user input
   - `M.handle_plan_approval()` - Handle PLAN_APPROVAL_REQUIRED with user approval

3. **Project Detection**
   - `M.get_git_remote_url()` - Detect git remote URL from current directory
   - `M.parse_gitlab_remote()` - Parse namespace/project from git URLs
   - `M.get_current_project_path()` - Get GitLab project path
   - `M.query_gitlab_project()` - Query GitLab API for project details
   - `M.get_project_ids()` - Get numeric project and namespace IDs

4. **LSP Integration**
   - `M.setup()` - Setup LSP handlers
   - `M._register_handlers()` - Register workflow message and command handlers
   - `M.sync_lsp_config()` - Sync configuration with LSP client
   - Handler for `$/gitlab/workflowMessage` notification
   - Handler for `$/gitlab/runCommand` request

5. **Error Handling**
   - `M.error_codes` - Error status code mapping
   - `M.get_error_message()` - Get human-readable error messages
   - `M.on_error()` - Handle workflow errors with status codes

6. **Status Indicators**
   - `M.status_icons` - Visual status indicators for different workflow states
   - Support for CREATED, RUNNING, FINISHED, FAILED, STOPPED, INPUT_REQUIRED, PLAN_APPROVAL_REQUIRED, TOOL_CALL_APPROVAL_REQUIRED

7. **Context Integration**
   - Automatic file context inclusion in workflows
   - Support for current buffer content
   - File metadata (path, name) in context

## API Reference

### Workflow Control Functions

#### M.send_workflow_event(workflow_id, event_type, message)

Send an event to a workflow.

**Parameters:**
- `workflow_id` (string): The workflow ID
- `event_type` (string): One of 'pause', 'resume', 'stop', 'message'
- `message` (table|nil): Optional message payload

**Returns:** boolean - Success status

**Example:**
```lua
local gitlab_duo = require('avante.providers.gitlab_duo')
gitlab_duo.send_workflow_event('workflow_123', 'stop')
```

#### M.stop_workflow(workflow_id)

Stop a running workflow.

**Parameters:**
- `workflow_id` (string): The workflow ID

**Example:**
```lua
gitlab_duo.stop_workflow('workflow_123')
```

#### M.pause_workflow(workflow_id)

Pause a running workflow.

**Parameters:**
- `workflow_id` (string): The workflow ID

**Returns:** boolean - Success status

#### M.resume_workflow(workflow_id)

Resume a paused workflow.

**Parameters:**
- `workflow_id` (string): The workflow ID

**Returns:** boolean - Success status

#### M.send_user_message(workflow_id, message, correlation_id)

Send a user message to a workflow.

**Parameters:**
- `workflow_id` (string): The workflow ID
- `message` (string): The user's message
- `correlation_id` (string|nil): Optional correlation ID for responses

**Returns:** boolean - Success status

**Example:**
```lua
gitlab_duo.send_user_message('workflow_123', 'approved', 'corr_456')
```

### User Interaction Handlers

#### M.handle_tool_approval(workflow_id, chat_log)

Handle tool approval requests with interactive user prompts.

**Parameters:**
- `workflow_id` (string): The workflow ID
- `chat_log` (table[]): The workflow chat log

**Behavior:**
- Finds the latest tool approval request in chat log
- Prompts user with `vim.ui.select` for approval choice
- Options: "Approve Once", "Approve for Session", "Reject"
- Sends approval response to GitLab LSP

#### M.handle_input_required(workflow_id, chat_log)

Handle INPUT_REQUIRED status with user input.

**Parameters:**
- `workflow_id` (string): The workflow ID
- `chat_log` (table[]): The workflow chat log

**Behavior:**
- Finds the latest input request in chat log
- Prompts user with `vim.ui.input` for input
- Sends user input to workflow via `send_user_message`

#### M.handle_plan_approval(workflow_id, plan)

Handle PLAN_APPROVAL_REQUIRED status with user approval.

**Parameters:**
- `workflow_id` (string): The workflow ID
- `plan` (table|nil): The agent's execution plan

**Behavior:**
- Displays plan steps to user
- Prompts user with `vim.ui.select` for approval choice
- Options: "Approve", "Reject", "Modify"
- Sends approval response to workflow

### Project Detection Functions

#### M.get_git_remote_url()

Get git remote URL from the current working directory.

**Returns:** string|nil - The git remote URL or nil if not found

**Example:**
```lua
local url = gitlab_duo.get_git_remote_url()
-- Returns: "https://gitlab.com/namespace/project.git"
```

#### M.parse_gitlab_remote(remote_url)

Parse GitLab namespace and project from git remote URL.

**Parameters:**
- `remote_url` (string): The git remote URL

**Returns:**
- `namespace` (string|nil): The GitLab namespace
- `project` (string|nil): The GitLab project name

**Supports:**
- HTTPS URLs: `https://gitlab.com/namespace/project.git`
- SSH URLs: `git@gitlab.com:namespace/project.git`
- Nested namespaces: `https://gitlab.com/group/subgroup/project.git`

#### M.get_current_project_path()

Get GitLab project path (namespace/project) from current git repository.

**Returns:** string|nil - The project path or nil if not found

**Example:**
```lua
local path = gitlab_duo.get_current_project_path()
-- Returns: "namespace/project"
```

#### M.query_gitlab_project(project_path)

Query GitLab API to get project information.

**Parameters:**
- `project_path` (string): The namespace/project path

**Returns:** table|nil - Project data with id and namespace fields

**Requires:** `GITLAB_TOKEN` environment variable

**Example:**
```lua
local project_data = gitlab_duo.query_gitlab_project('namespace/project')
-- Returns: { id = 12345, namespace = { id = 67890, ... }, ... }
```

#### M.get_project_ids()

Get GitLab project ID and namespace ID from current repository.

**Returns:**
- `project_id` (string|nil): The numeric project ID
- `namespace_id` (string|nil): The numeric namespace ID

**Example:**
```lua
local project_id, namespace_id = gitlab_duo.get_project_ids()
-- Returns: "12345", "67890"
```

### LSP Integration Functions

#### M.get_gitlab_client()

Get the active GitLab LSP client.

**Returns:** table|nil - The LSP client or nil if not found

**Supports:**
- `gitlab_lsp` client name
- `gitlab_code_suggestions` client name

#### M.sync_lsp_config(client, project_path)

Sync configuration with GitLab LSP.

**Parameters:**
- `client` (table): The LSP client
- `project_path` (string|nil): The project path (namespace/project)

**Behavior:**
- Sends `workspace/didChangeConfiguration` notification
- Includes token, baseUrl, projectPath
- Enables duo.workflow and duo.agentPlatform
- Sets featureFlags.duoWorkflow = true

**Critical:** This must be called before starting workflows to ensure LSP has correct configuration.

#### M.setup()

Setup LSP handlers for GitLab Duo.

**Behavior:**
- Schedules handler registration after LSP clients are initialized
- Sets up autocmd for late LSP attachment
- Calls `M._register_handlers()` when client is available

**Called automatically:** By avante.nvim when the provider is loaded

#### M._register_handlers(client)

Register LSP handlers for GitLab Duo.

**Parameters:**
- `client` (table): The LSP client

**Registers:**
- Handler for `$/gitlab/workflowMessage` notification
- Handler for `$/gitlab/runCommand` request

### Error Handling Functions

#### M.get_error_message(error_code, default_message)

Get human-readable error message from error code.

**Parameters:**
- `error_code` (number|nil): The error status code
- `default_message` (string|nil): Default message if code not found

**Returns:** string - The error message

**Supported Error Codes:**
- `1`: Your request was valid but Workflow failed to complete it
- `2`: Workflow failed to start
- `3`: Workflow could not use your token to connect to GitLab
- `6`: Workflow could not connect to the Workflow service
- `50`: Error fetching authentication token
- `51`: GitLab API configuration details unavailable
- `52`: Unsupported connection type

#### M.on_error(result)

Handle errors from GitLab Duo.

**Parameters:**
- `result` (table): The error result

**Behavior:**
- Parses error code and message from result
- Maps error code to human-readable message
- Displays error with `Utils.error()`

## Workflow Lifecycle

### 1. Starting a Workflow

```lua
-- Called automatically by avante.nvim
M:parse_curl_args(prompt_opts)
```

**Process:**
1. Get GitLab LSP client
2. Extract goal from user message
3. Build context from current buffer
4. Auto-detect project IDs from git
5. Sync LSP configuration
6. Send `$/gitlab/startWorkflow` request
7. Store workflow ID in `M.active_workflows`

### 2. Receiving Workflow Updates

```lua
-- LSP handler receives $/gitlab/workflowMessage notification
client.handlers["$/gitlab/workflowMessage"] = function(err, result, ctx)
  M.handle_workflow_message(workflow_id, result)
end
```

**Process:**
1. Extract workflow ID from result
2. Parse checkpoint JSON
3. Extract chat log and status
4. Update `M.active_workflows` state
5. Trigger status-specific handlers

### 3. Parsing Workflow Responses

```lua
-- Called by avante.nvim streaming handler
M:parse_response(ctx, data_stream, event_state, opts)
```

**Process:**
1. Get workflow from `M.active_workflows`
2. Process new messages in chat log
3. Stream agent messages via `opts.on_chunk`
4. Display tool execution messages
5. Check workflow status
6. Handle status-specific actions

### 4. Workflow Status Handling

#### FINISHED
```lua
if workflow.status == "FINISHED" then
  opts.on_stop({ reason = "complete" })
end
```

#### FAILED
```lua
if workflow.status == "FAILED" then
  opts.on_stop({
    reason = "error",
    error = { message = table.concat(workflow.errors, "\n") },
  })
end
```

#### TOOL_CALL_APPROVAL_REQUIRED
```lua
if workflow.status == "TOOL_CALL_APPROVAL_REQUIRED" then
  M.handle_tool_approval(workflow_id, chat_log)
end
```

#### INPUT_REQUIRED
```lua
if workflow.status == "INPUT_REQUIRED" then
  M.handle_input_required(workflow_id, chat_log)
end
```

#### PLAN_APPROVAL_REQUIRED
```lua
if workflow.status == "PLAN_APPROVAL_REQUIRED" then
  local plan = workflow.checkpoint.channel_values.plan
  M.handle_plan_approval(workflow_id, plan)
end
```

### 5. Stopping a Workflow

```lua
M.stop_workflow(workflow_id)
```

**Process:**
1. Send `$/gitlab/sendWorkflowEvent` with eventType = 'stop'
2. Remove workflow from `M.active_workflows`

## Configuration

### Required Environment Variables

```bash
export GITLAB_TOKEN="glpat-xxxxxxxxxxxxx"
```

### Avante Configuration

```lua
require('avante').setup({
  debug = true,  -- Enable to see detection logs
  provider = "gitlab_duo",
  vendors = {
    gitlab_duo = {
      model = "claude-3-5-sonnet",
      -- project_id and namespace_id auto-detected from git
      -- or set explicitly if needed:
      -- project_id = "12345",
      -- namespace_id = "67890",
    }
  }
})
```

## Message Types

### User Message
```lua
{
  message_type = "user",
  content = "User's message",
  timestamp = "2024-01-01T00:00:00Z",
  correlation_id = "corr_123",
}
```

### Agent Message
```lua
{
  message_type = "agent",
  content = "Agent's response",
  timestamp = "2024-01-01T00:00:00Z",
}
```

### Tool Message
```lua
{
  message_type = "tool",
  content = "Tool execution description",
  tool_info = {
    name = "read_file",
    args = { path = "/path/to/file" },
    tool_response = {
      content = "File content...",
      status = "success",
    },
  },
}
```

### Request Message (Tool Approval)
```lua
{
  message_type = "request",
  content = "Description of what needs approval",
  correlation_id = "corr_456",
  tool_info = {
    name = "run_command",
    args = { command = "ls", args = {"-la"} },
  },
}
```

## Status Icons

The provider includes visual status indicators:

- 🔵 `CREATED` - Workflow created
- ⏳ `RUNNING` - Workflow running
- ✅ `FINISHED` - Workflow completed successfully
- ❌ `FAILED` - Workflow failed
- ⏹️ `STOPPED` - Workflow stopped by user
- ❓ `INPUT_REQUIRED` - Workflow needs user input
- 📋 `PLAN_APPROVAL_REQUIRED` - Workflow needs plan approval
- 🔧 `TOOL_CALL_APPROVAL_REQUIRED` - Workflow needs tool approval

## Debugging

Enable debug mode in Avante configuration:

```lua
require('avante').setup({
  debug = true,
  provider = "gitlab_duo",
})
```

Debug logs will show:
- Git remote detection
- Project ID detection
- LSP configuration sync
- Workflow start/stop events
- Message processing
- Status changes

## Comparison with Specification

This implementation fully satisfies the requirements in `prompt.md`:

| Specification Requirement | Implementation Status | Notes |
|--------------------------|----------------------|-------|
| LSP client detection | ✅ Implemented | `get_gitlab_client()` |
| Start workflow | ✅ Implemented | `parse_curl_args()` |
| Workflow message handler | ✅ Implemented | `handle_workflow_message()` |
| Command execution handler | ✅ Implemented | Handler for `$/gitlab/runCommand` |
| Stop workflow | ✅ Implemented | `stop_workflow()` |
| Pause/Resume workflow | ✅ Implemented | `pause_workflow()`, `resume_workflow()` |
| Send user messages | ✅ Implemented | `send_user_message()` |
| Tool approval flow | ✅ Implemented | `handle_tool_approval()` with UI |
| Plan approval flow | ✅ Implemented | `handle_plan_approval()` with UI |
| Input required handling | ✅ Implemented | `handle_input_required()` with UI |
| Error handling | ✅ Implemented | `on_error()` with status codes |
| Status indicators | ✅ Implemented | `status_icons` table |
| Context integration | ✅ Implemented | File context in `parse_curl_args()` |
| Project detection | ✅ Implemented | Git + GitLab API integration |
| LSP config sync | ✅ Implemented | `sync_lsp_config()` |

## Known Limitations

1. **Visual Selection Context**: Currently only includes full file content, not visual selections
2. **Workflow ID Tracking**: Falls back to goal matching if workflow ID not provided by LSP
3. **Multi-file Context**: Only includes current buffer, not multiple files
4. **Project ID Caching**: Queries GitLab API on every workflow start (could be cached)

## Future Enhancements

1. **Visual Selection Support**: Add visual selection to context when available
2. **Better Workflow ID Tracking**: Improve workflow ID extraction from LSP responses
3. **Multi-file Context**: Support adding multiple files to workflow context
4. **Project ID Caching**: Cache project IDs to avoid repeated API calls
5. **Workflow History**: Track workflow history for debugging
6. **Custom Tool Approval Rules**: Allow configuring auto-approval for specific tools
7. **Streaming UI Updates**: Show real-time status updates in Avante UI

## Testing

### Manual Testing Checklist

- [ ] Workflow starts successfully
- [ ] Agent messages are displayed
- [ ] Tool execution messages are shown
- [ ] Tool approval prompts appear
- [ ] Tool approval works (approve once, session, reject)
- [ ] Input required prompts appear
- [ ] User input is sent correctly
- [ ] Plan approval prompts appear
- [ ] Plan approval works (approve, reject, modify)
- [ ] Workflow completes successfully
- [ ] Workflow failures are handled
- [ ] Error messages are displayed
- [ ] Project auto-detection works
- [ ] Stop workflow works
- [ ] Command execution works

### Test Scenarios

1. **Basic Workflow**
   - Open a file in a GitLab repository
   - Ask: "Explain this file"
   - Verify agent response

2. **Tool Approval**
   - Ask: "Read the README.md file"
   - Verify tool approval prompt
   - Approve tool
   - Verify file content is displayed

3. **Input Required**
   - Ask: "What file should I explain?"
   - Verify input prompt
   - Provide filename
   - Verify agent response

4. **Plan Approval**
   - Ask: "Refactor this code to use modern patterns"
   - Verify plan approval prompt
   - Approve plan
   - Verify refactoring is performed

5. **Error Handling**
   - Disconnect from GitLab
   - Start workflow
   - Verify error message with code

## References

- Original specification: `prompt.md`
- GitLab LSP: https://gitlab.com/gitlab-org/gitlab-lsp
- GitLab VS Code Extension: https://gitlab.com/gitlab-org/gitlab-vscode-extension
- Avante.nvim: https://github.com/yetone/avante.nvim


# GitLab Duo Provider Diagnostic Guide

This guide will help you diagnose why the gitlab_duo provider works in VS Code but not in Avante.nvim.

## Step 1: Enable Debug Logging

Add this to your Neovim configuration:

```lua
require('avante').setup({
  provider = "gitlab_duo",
  debug = true, -- Enable debug logging
  providers = {
    gitlab_duo = {
      model = "claude-3-5-sonnet",
      project_id = "your-project-id",
      namespace_id = "your-namespace-id",
    },
  },
})
```

## Step 2: Reproduce the Issue

1. Open a file in Neovim
2. Run `:AvanteAsk` and submit a prompt
3. Wait for the error or timeout

## Step 3: Collect Logs

Run this command in Neovim to view all debug messages:

```vim
:messages
```

Copy the entire output and look for these key messages:

### Expected Log Sequence (Working)

```
GitLab Duo setup: checking for LSP client...
GitLab Duo setup: gitlab_code_suggestions client found, registering handlers...
Registering GitLab Duo LSP handlers...
Registered handler for $/gitlab/workflowMessage
Starting GitLab Duo workflow with goal: <your prompt>
GitLab Duo workflow started with ID: <workflow-id>
Active workflows: <workflow-id>
Received $/gitlab/workflowMessage notification
Workflow message result: {...}
handle_workflow_message called for workflow_id: <workflow-id>
parse_response: workflow status=RUNNING, chat_log size=0
parse_response: processing N new messages
parse_response: agent message, length=<length>
parse_response: workflow FINISHED
```

### Actual Log Sequence (Failing)

Compare your logs with the expected sequence above. Common issues:

1. **LSP client not found**
   ```
   GitLab Duo setup: gitlab_code_suggestions client not found, waiting for LspAttach...
   ```
   → The GitLab LSP server isn't running. Run `:LspInfo` to check.

2. **No workflow message notifications**
   - Setup completes successfully
   - Workflow starts with ID
   - But "Received $/gitlab/workflowMessage notification" never appears
   → The LSP handler isn't being called by the GitLab server

3. **Workflow ID mismatch**
   ```
   parse_response: workflow not found for ID: avante_12345_6789
   Active workflows: <different-id>
   ```
   → The workflow ID from GitLab doesn't match what we're tracking

4. **Missing checkpoint**
   ```
   handle_workflow_message: missing checkpoint, result.checkpoint=nil
   ```
   → The GitLab response doesn't have the expected structure

## Step 4: Check LSP Server Logs

Get the LSP log path:

```vim
:lua print(vim.lsp.get_log_path())
```

Open that file and look for:
- Connection errors
- Request/response mismatches
- Protocol errors

## Step 5: Compare with VS Code

To understand how VS Code handles this differently:

1. **VS Code Extension Logs**
   - In VS Code, open Output panel (Ctrl+Shift+U)
   - Select "GitLab Duo" or "GitLab LSP" from dropdown
   - Look for similar messages

2. **Key Differences to Check**
   - Does VS Code use `request_sync` or `request` (async)?
   - Does it use `notify` instead of `request_sync`?
   - Different workflow parameter names?
   - Different handler registration method?

## Step 6: Diagnostic Checklist

Run through this checklist to identify the issue:

### LSP Server
- [ ] `gitlab_code_suggestions` client appears in `:LspInfo`
- [ ] Client shows as "attached" to current buffer
- [ ] No LSP errors in log file

### Workflow Start
- [ ] "Starting GitLab Duo workflow" message appears
- [ ] "GitLab Duo workflow started with ID" message appears
- [ ] Workflow ID is not empty/nil

### Workflow Updates
- [ ] "Received $/gitlab/workflowMessage notification" appears
- [ ] Notification contains `workflowStatus` field
- [ ] Notification contains `checkpoint` field
- [ ] Checkpoint can be JSON decoded

### Workflow Progress
- [ ] "parse_response: workflow status=" messages appear
- [ ] Status changes from RUNNING to FINISHED
- [ ] Chat log contains agent messages

## Step 7: Send Diagnostic Information

If you're still stuck, collect this information:

```vim
" Get Neovim version
:version

" Get LSP info
:LspInfo

" Get all messages
:messages

" Get LSP logs
:lua print(vim.lsp.get_log_path())
```

Then share:
1. Your Avante config (redact tokens)
2. The `:messages` output
3. The LSP log file content
4. Which step in the diagnostic checklist fails

## Possible Root Causes

### Issue 1: `request_sync` Not Supported
**Symptom**: Workflow starts but no ID returned

**Fix**: Change from `request_sync` to `request` (async)
```lua
-- In gitlab_duo.lua
local success, result = client.request("$/gitlab/startWorkflow", workflow_params, function(err, response)
  -- Handle response
end)
```

### Issue 2: Handler Registration Timing
**Symptom**: LSP client found but handlers not registered before workflow starts

**Fix**: Ensure handlers are registered before returning from `parse_curl_args`
```lua
-- Make sure M.setup() completes synchronously
M.setup()
-- Wait for handlers to be registered
vim.wait(1000, function()
  return client.handlers["$/gitlab/workflowMessage"] ~= nil
end)
```

### Issue 3: Workflow ID Format Mismatch
**Symptom**: Workflow starts but "workflow not found" errors

**Fix**: Log the actual workflow ID from response
```lua
Utils.debug("Response workflow ID: " .. vim.inspect(result.result))
-- Check if it's in a different field like:
-- result.result.id
-- result.result.workflow_id (snake_case)
-- result.result.workflowId (camelCase)
```

### Issue 4: LSP Notification Handler Not Called
**Symptom**: Everything starts but no notifications received

**Fix**: Check if handler is registered correctly
```lua
-- After registering handler
local handler = client.handlers["$/gitlab/workflowMessage"]
Utils.debug("Handler registered: " .. tostring(handler ~= nil))

-- Add a fallback handler that catches all notifications
vim.lsp.handlers.default = function(method, params, ctx)
  Utils.debug("Received LSP notification: " .. method)
  Utils.debug("Params: " .. vim.inspect(params))
end
```

## Next Steps

1. **Enable debug mode** in your config
2. **Reproduce the issue** and collect logs
3. **Check the diagnostic checklist** to identify the failure point
4. **Try the suggested fixes** for your specific issue
5. **Share diagnostic info** if you need help

## Related Files

- Main provider: `lua/avante/providers/gitlab_duo.lua`
- LSP integration: `lua/avante/llm.lua` (LSP provider handling)
- Configuration: `lua/avante/config.lua`
- Types: `lua/avante/types.lua`


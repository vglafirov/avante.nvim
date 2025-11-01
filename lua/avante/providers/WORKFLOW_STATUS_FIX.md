# GitLab Duo Workflow Status Handling Fix

## Problem

The GitLab Duo provider was not properly detecting workflow status changes. Specifically:

1. **Workflows always showed as "RUNNING"** in logs even when they had finished or required user input
2. **"INPUT_REQUIRED" status was not being detected**, causing workflows to appear stuck
3. **Workflow status updates weren't being properly extracted** from LSP notifications

## Root Causes

### 1. Incomplete Status Field Extraction

The original code only checked a limited set of fields for the workflow status:

```lua
-- OLD CODE - Only checked result.workflowStatus
local workflow_status = result.workflowStatus or "RUNNING"
```

**Problem**: GitLab LSP may send the status in different field names:
- `result.workflowStatus` (camelCase)
- `result.workflow_status` (snake_case)
- `result.status` (short form)
- `checkpoint.channel_values.status` (nested in checkpoint)
- `checkpoint.metadata.status` (nested in metadata)

### 2. Insufficient Debug Logging

The original debug logging didn't show:
- The complete structure of the result object
- All possible status field candidates
- The full checkpoint structure

This made it difficult to diagnose where the status was actually located.

### 3. Workflow ID Matching Issues

The LSP notification handler had limited fallback logic for matching workflow IDs:

```lua
-- OLD CODE - Limited matching
local workflow_id = result.workflowId or result.workflow_id
if not workflow_id then
  -- Try to find by goal
  for id, workflow in pairs(M.active_workflows) do
    if workflow.goal == result.workflowGoal then
      workflow_id = id
      break
    end
  end
end
```

**Problem**: If GitLab didn't include the workflow ID in the notification, or if the goal didn't match exactly, the notification would be ignored.

## Solutions Implemented

### 1. Enhanced Status Extraction

Now checks ALL possible status field locations with proper fallback chain:

```lua
-- NEW CODE - Comprehensive status extraction
local workflow_status = result.workflowStatus
  or result.workflow_status
  or result.status
  or (checkpoint.channel_values and checkpoint.channel_values.status)
  or (checkpoint.metadata and checkpoint.metadata.status)
  or (checkpoint.metadata and checkpoint.metadata.workflowStatus)
  or "RUNNING"
```

This ensures the status is found regardless of where GitLab places it in the notification.

### 2. Comprehensive Debug Logging

Added detailed logging to help diagnose issues:

```lua
-- Log full result structure
Utils.debug("Result full structure: " .. vim.inspect(result))

-- Log all status field candidates
Utils.debug("Status field candidates: workflowStatus=" .. tostring(result.workflowStatus)
  .. ", workflow_status=" .. tostring(result.workflow_status)
  .. ", status=" .. tostring(result.status)
  .. ", checkpoint.channel_values.status=" .. tostring(checkpoint.channel_values and checkpoint.channel_values.status)
  .. ", checkpoint.metadata.status=" .. tostring(checkpoint.metadata and checkpoint.metadata.status))
```

### 3. Improved Workflow ID Matching

Enhanced the fallback logic with multiple strategies:

```lua
-- NEW CODE - Multiple fallback strategies
local workflow_id = result.workflowId or result.workflow_id or result.id

if not workflow_id then
  -- Strategy 1: Match by goal
  local goal = result.workflowGoal or result.workflow_goal or result.goal
  if goal then
    for id, workflow in pairs(M.active_workflows) do
      if workflow.goal == goal then
        workflow_id = id
        break
      end
    end
  end

  -- Strategy 2: If only one active workflow, use it
  if not workflow_id then
    local active_ids = vim.tbl_keys(M.active_workflows)
    if #active_ids == 1 then
      workflow_id = active_ids[1]
    end
  end
end
```

### 4. Added Workflow Update Event

Added an autocmd event to notify when workflow state changes:

```lua
vim.schedule(function()
  vim.api.nvim_exec_autocmds("User", {
    pattern = "AvanteGitLabDuoWorkflowUpdate",
    data = { workflow_id = workflow_id }
  })
end)
```

This helps ensure the `parse_response` function picks up status changes.

## Workflow Status Flow

Here's how workflow status updates now flow through the system:

```
GitLab LSP Server
    ↓
$/gitlab/workflowMessage notification
    ↓
_register_handlers() LSP handler
    ↓
handle_workflow_message()
    ├─ Extract workflow ID (multiple strategies)
    ├─ Extract status (check all possible fields)
    ├─ Parse checkpoint JSON
    ├─ Extract chat_log
    └─ Update M.active_workflows[workflow_id]
    ↓
Trigger AvanteGitLabDuoWorkflowUpdate event
    ↓
parse_response() picks up changes
    ├─ Check workflow status
    ├─ Process new chat messages
    └─ Handle special statuses:
        ├─ FINISHED → call on_stop
        ├─ FAILED → call on_stop with error
        ├─ INPUT_REQUIRED → prompt user for input
        ├─ TOOL_CALL_APPROVAL_REQUIRED → prompt for tool approval
        └─ PLAN_APPROVAL_REQUIRED → prompt for plan approval
```

## Supported Workflow Statuses

The provider now properly handles these GitLab Duo workflow statuses:

| Status | Description | Action |
|--------|-------------|--------|
| `CREATED` | Workflow has been created | Continue monitoring |
| `RUNNING` | Workflow is executing | Continue monitoring |
| `FINISHED` | Workflow completed successfully | Call `on_stop({ reason = "complete" })` |
| `FAILED` | Workflow failed with errors | Call `on_stop({ reason = "error", error = ... })` |
| `STOPPED` | Workflow was manually stopped | Clean up workflow state |
| `INPUT_REQUIRED` | Agent needs user input | Prompt user with `vim.ui.input()` |
| `TOOL_CALL_APPROVAL_REQUIRED` | Tool needs approval | Prompt user with approval options |
| `PLAN_APPROVAL_REQUIRED` | Execution plan needs approval | Show plan and prompt for approval |

## Testing

To verify the fix is working:

1. **Enable debug logging**: Set `AVANTE_DEBUG=1` in your environment
2. **Start a workflow** that requires user input
3. **Check the logs** for:
   ```
   Result full structure: { ... }
   Status field candidates: workflowStatus=nil, workflow_status=nil, status=INPUT_REQUIRED, ...
   handle_workflow_message: status=INPUT_REQUIRED, chat_log size=X, errors={}
   parse_response: workflow status=INPUT_REQUIRED, chat_log size=X
   parse_response: workflow requires input
   ```
4. **Verify the UI** prompts you for input when status is `INPUT_REQUIRED`

## Expected Behavior After Fix

1. ✅ Workflow status changes are properly detected
2. ✅ `INPUT_REQUIRED` status triggers user input prompt
3. ✅ `FINISHED` status properly completes the workflow
4. ✅ `FAILED` status shows error messages
5. ✅ Debug logs show the complete workflow state
6. ✅ Workflow ID matching works even without explicit ID in notifications

## Debugging Tips

If workflow status is still not being detected:

1. **Check the logs** for "Result full structure" to see what GitLab is actually sending
2. **Look for "Status field candidates"** to see which fields are present
3. **Verify workflow ID matching** - look for "Found workflow ID" or "Using single active workflow"
4. **Check for errors** in checkpoint parsing - "Failed to parse workflow checkpoint"
5. **Ensure LSP handlers are registered** - look for "GitLab Duo LSP handlers registered"

## Related Files

- `lua/avante/providers/gitlab_duo.lua` - Main provider implementation
- `lua/avante/providers/README_GITLAB_DUO.md` - User documentation
- `lua/avante/providers/IMPLEMENTATION_SUMMARY.md` - Implementation details


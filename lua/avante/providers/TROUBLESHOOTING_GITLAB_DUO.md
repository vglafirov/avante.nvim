# GitLab Duo Provider Troubleshooting Guide

This guide helps you diagnose and fix common issues with the GitLab Duo provider for Avante.nvim.

## Error: "The Duo Agent Platform feature is not enabled"

### What it means
This error indicates that your GitLab instance doesn't have the Duo Agent Platform feature enabled or accessible.

### Possible causes

1. **GitLab instance doesn't support Duo Agent Platform**
   - Duo Agent Platform is a premium feature
   - Available in GitLab Ultimate (SaaS and Self-Managed)
   - Requires GitLab 17.0 or later

2. **Project doesn't have access**
   - Your project might not be in a group/namespace with Duo enabled
   - The feature might be disabled at the group or project level

3. **Authentication issues**
   - Your GitLab token might not have the necessary permissions
   - Token might be expired or invalid

### How to fix

#### Check GitLab instance support
1. Go to your GitLab instance
2. Navigate to Admin Area → Settings → General → AI-powered features
3. Verify that "GitLab Duo" is enabled

#### Check project/group access
1. Go to your project settings
2. Navigate to Settings → General → Visibility, project features, permissions
3. Check if "GitLab Duo" features are enabled

#### Verify token permissions
Your GitLab token needs these scopes:
- `api` - Full API access
- `read_repository` - Read repository content
- `write_repository` - Write repository content (for code suggestions)

To create/update your token:
1. Go to GitLab → Preferences → Access Tokens
2. Create a new token with the required scopes
3. Update your `~/.gitlab-token` or environment variable

#### Update your configuration
Make sure your Neovim configuration includes:

```lua
require('lspconfig').gitlab_lsp.setup({
  cmd = { "gitlab-lsp", "--stdio" },
  settings = {
    gitlab = {
      baseUrl = "https://gitlab.com", -- or your instance URL
      token = vim.env.GITLAB_TOKEN,
    },
  },
})

require('avante').setup({
  provider = "gitlab_duo",
  providers = {
    gitlab_duo = {
      model = "claude-3-5-sonnet",
      project_id = "12345", -- Your project ID
      namespace_id = "67890", -- Your namespace/group ID
    },
  },
  debug = true, -- Enable for detailed logging
})
```

## Error: "GitLab LSP client not found"

### What it means
The GitLab Language Server is not running or not attached to your buffer.

### How to fix

1. **Check if gitlab-lsp is installed**
   ```bash
   which gitlab-lsp
   ```

2. **Check LSP status in Neovim**
   ```vim
   :LspInfo
   ```
   You should see `gitlab_code_suggestions` in the list of attached clients.

3. **Restart the LSP server**
   ```vim
   :LspRestart
   ```

4. **Check LSP logs**
   ```vim
   :lua vim.cmd('e ' .. vim.lsp.get_log_path())
   ```

## Error: "LSP provider timeout after 5 minutes"

### What it means
The workflow didn't complete within 5 minutes.

### Possible causes
1. GitLab server is slow or unresponsive
2. Network connectivity issues
3. Workflow is stuck waiting for approval
4. LSP notifications aren't being received

### How to fix

1. **Enable debug logging**
   ```lua
   require('avante').setup({
     debug = true,
     -- ... other config
   })
   ```

2. **Check the logs**
   ```vim
   :messages
   ```
   Look for:
   - "Starting GitLab Duo workflow with goal: ..."
   - "GitLab Duo workflow started with ID: ..."
   - "Received $/gitlab/workflowMessage notification"
   - "parse_response: workflow status=..."

3. **Check network connectivity**
   ```bash
   curl -H "PRIVATE-TOKEN: your-token" https://gitlab.com/api/v4/user
   ```

4. **Increase timeout** (if workflows are legitimately slow)
   ```lua
   require('avante').setup({
     providers = {
       gitlab_duo = {
         timeout = 600000, -- 10 minutes
       },
     },
   })
   ```

## Error: "Failed to parse workflow checkpoint"

### What it means
The response from GitLab LSP couldn't be parsed as JSON.

### How to fix
1. Check gitlab-lsp logs for errors
2. Ensure you're using a compatible version of gitlab-lsp
3. Try restarting the LSP server

## Common Issues

### Workflows start but never complete

**Symptoms:**
- Workflow starts successfully
- No responses appear
- Eventually times out

**Diagnosis:**
```lua
-- Enable debug mode and check logs
require('avante').setup({ debug = true })
```

Look for these log messages:
- "Registered handler for $/gitlab/workflowMessage" - Should appear once
- "Received $/gitlab/workflowMessage notification" - Should appear multiple times during workflow
- "parse_response: workflow status=..." - Shows workflow progress

**Possible fixes:**
1. LSP handlers not registered - Restart Neovim
2. Workflow ID mismatch - Check logs for "workflow not found" messages
3. GitLab not sending notifications - Check gitlab-lsp logs

### Slow performance

**Symptoms:**
- Long delays before responses appear
- Workflows take several minutes

**Possible causes:**
1. Network latency to GitLab instance
2. Complex workflows requiring many tool executions
3. Large file contexts being sent

**Optimizations:**
1. Use a faster network connection
2. Reduce file size being sent as context
3. Use a GitLab instance closer to you geographically

### Tool approval issues

**Symptoms:**
- Workflow hangs at "TOOL_CALL_APPROVAL_REQUIRED"
- No approval prompts appear

**Fix:**
The provider currently auto-approves tools. If this isn't working:
1. Check logs for "workflow requires tool approval" messages
2. Verify the approval notification is being sent
3. Check gitlab-lsp logs for approval responses

## Getting Help

If you're still experiencing issues:

1. **Collect diagnostic information:**
   ```vim
   :messages > ~/avante-debug.log
   :lua vim.cmd('e ' .. vim.lsp.get_log_path())
   " Copy the LSP log content
   ```

2. **Check GitLab LSP status:**
   ```vim
   :LspInfo
   :checkhealth lsp
   ```

3. **Create an issue** with:
   - Your Neovim version (`:version`)
   - Your gitlab-lsp version (`gitlab-lsp --version`)
   - Your Avante.nvim configuration
   - The error messages from logs
   - Steps to reproduce

## Additional Resources

- [GitLab Duo Documentation](https://docs.gitlab.com/ee/user/ai_features.html)
- [GitLab LSP Repository](https://gitlab.com/gitlab-org/editor-extensions/gitlab-lsp)
- [Avante.nvim Issues](https://github.com/yetone/avante.nvim/issues)


# GitLab Duo Provider Fix Summary

## Problem Identified

The GitLab Duo provider was throwing the error "Duo Agent Platform feature is not enabled" even though the same project and personal access token worked in VS Code.

**Root Cause**: The provider was sending `projectId: nil` and `namespaceId: nil` in the workflow metadata, which caused GitLab to reject the workflow request.

## Analysis

### What the prompt.md Document Required

According to the `prompt.md` specification, the `$/gitlab/startWorkflow` notification should include:

```typescript
{
  goal: string;
  metadata: {
    projectId?: string;              // GitLab project ID (numeric)
    namespaceId?: string;            // GitLab namespace ID (numeric)
    selectedModelIdentifier?: string; // AI model to use
  };
  additionalContext?: AIContextItem[];
}
```

### What Was Wrong

The original implementation:
1. Set `project_id` and `namespace_id` to `nil` in the default config
2. Directly passed these `nil` values to the LSP without any auto-detection
3. Did not query the GitLab API to get the numeric IDs

### Why It Worked in VS Code

The VS Code extension automatically:
1. Detects the git remote URL
2. Parses the namespace/project path
3. Queries the GitLab API to get project details (including numeric IDs)
4. Populates the project_id and namespace_id fields with numeric values

## Solution Implemented

### 1. Git Remote Detection

Added function to detect the git remote URL from the current buffer's directory:

```lua
function M.get_git_remote_url()
  local filepath = vim.api.nvim_buf_get_name(0)
  local dir = vim.fn.fnamemodify(filepath, ":h")
  local cmd = string.format("git -C %s remote get-url origin 2>/dev/null", vim.fn.shellescape(dir))
  local result = vim.fn.system(cmd)
  -- Returns the remote URL or nil
end
```

### 2. URL Parsing

Parses both HTTPS and SSH GitLab URLs to extract namespace/project:

```lua
function M.parse_gitlab_remote(remote_url)
  -- Handles: https://gitlab.com/namespace/project.git
  -- Handles: git@gitlab.com:namespace/project.git
  -- Returns: namespace, project
end
```

### 3. GitLab API Query

Queries the GitLab API to get numeric project and namespace IDs:

```lua
function M.query_gitlab_project(project_path)
  local token, base_url = M.get_gitlab_credentials()
  local encoded_path = project_path:gsub("/", "%%2F")
  local api_url = base_url .. "/api/v4/projects/" .. encoded_path

  -- Queries API using curl with LSP client's token
  -- Returns project data with numeric id and namespace.id
end
```

### 4. Credentials from LSP Client

Retrieves GitLab token and base URL from the LSP client settings:

```lua
function M.get_gitlab_credentials()
  local client = M.get_gitlab_client()
  local settings = client.config.settings
  local token = settings.gitlab.token
  local base_url = settings.gitlab.baseUrl or "https://gitlab.com"
  return token, base_url
end
```

### 5. Updated Workflow Initialization

Modified the workflow parameter building to use API-queried numeric IDs:

```lua
-- Get project IDs - prioritize config values, then auto-detect from git
local project_id = provider_conf.project_id
local namespace_id = provider_conf.namespace_id

-- If no explicit config values, try to auto-detect from git and query GitLab API
if not project_id or not namespace_id then
  Utils.debug("Attempting to auto-detect project from git repository...")
  local detected_project_id, detected_namespace_id = M.get_project_ids()

  if not project_id and detected_project_id then
    project_id = detected_project_id  -- Numeric ID from API
  end

  if not namespace_id and detected_namespace_id then
    namespace_id = detected_namespace_id  -- Numeric ID from API
  end
end

-- Build metadata with numeric IDs
local metadata = {
  selectedModelIdentifier = provider_conf.model,
}

if project_id then
  metadata.projectId = project_id
end

if namespace_id then
  metadata.namespaceId = namespace_id
end
```

## Key Features of the Fix

### 1. Automatic Project Detection
- Detects project from git remote URL automatically
- Queries GitLab API to get numeric IDs
- No manual configuration required for most use cases
- Works with both HTTPS and SSH URLs

### 2. GitLab API Integration
- Uses token from LSP client settings
- Queries `/api/v4/projects/:id` endpoint
- Extracts numeric `id` and `namespace.id`
- Works with gitlab.com and self-hosted instances

### 3. Proper ID Format
The provider now uses **numeric IDs** (not path format) as required by the GitLab Duo API:
- ✅ `projectId: "278964"` (numeric)
- ❌ ~~`projectId: "gitlab-org/gitlab"`~~ (path - not supported)

### 4. Graceful Fallback
- Uses config values if provided (takes precedence)
- Falls back to auto-detection if config is nil
- Shows warning if no project can be determined
- Only includes metadata fields that have values

### 5. Better Debugging
- Added debug logging for each step
- Shows detected remote URL
- Shows parsed project path
- Shows API query URL
- Shows numeric IDs retrieved
- Shows final metadata being sent

## Updated Documentation

### README Updates

- Clarified that numeric IDs are required
- Documented the auto-detection process (git → API → numeric IDs)
- Added troubleshooting for git detection issues
- Explained how to enable debug mode

### Configuration Documentation

Updated to explain:
- Auto-detection requires LSP client with valid token
- Numeric IDs are queried from GitLab API
- Manual configuration still supported
- How the detection process works

## Testing Recommendations

To test the fix:

1. **Test auto-detection in a GitLab repository**:
   ```lua
   require('avante').setup({
     debug = true,
     provider = "gitlab_duo",
   })
   ```
   Check `:messages` for:
   - "get_git_remote_url: Found remote URL: ..."
   - "Detected GitLab project path: ..."
   - "Querying GitLab API: ..."
   - "Successfully retrieved project info from GitLab API"
   - "Project ID: ..."
   - "Namespace ID: ..."

2. **Test manual configuration**:
   ```lua
   providers = {
     gitlab_duo = {
       project_id = "278964",  -- numeric ID
       namespace_id = "9970",  -- numeric ID
     },
   }
   ```

3. **Test outside GitLab repository**:
   Should show warning about no project detected

## Comparison with VS Code Extension

| Feature | VS Code Extension | Avante Provider (Fixed) |
|---------|------------------|------------------------|
| Auto-detect from git | ✅ Yes | ✅ Yes |
| Query GitLab API | ✅ Yes | ✅ Yes |
| Use numeric IDs | ✅ Yes | ✅ Yes |
| Parse HTTPS URLs | ✅ Yes | ✅ Yes |
| Parse SSH URLs | ✅ Yes | ✅ Yes |
| Manual override | ✅ Yes | ✅ Yes |
| Debug logging | ✅ Yes | ✅ Yes |
| Get token from LSP | ✅ Yes | ✅ Yes |

## Conclusion

The fix ensures that the Avante provider behaves identically to the VS Code extension by:

1. ✅ Detecting the git remote URL
2. ✅ Parsing the namespace/project path
3. ✅ Querying the GitLab API with the LSP client's token
4. ✅ Extracting numeric project_id and namespace_id
5. ✅ Sending these numeric IDs in the workflow metadata

The provider now properly implements the requirements from `prompt.md` and should work identically to VS Code when used in a GitLab repository with a configured LSP client.


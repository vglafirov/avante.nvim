local Utils = require("avante.utils")
local P = require("avante.providers")
local HistoryMessage = require("avante.history.message")

---@class AvanteProviderFunctor
local M = {}

M.api_key_name = "" -- GitLab Duo uses LSP, no API key needed
M.support_prompt_caching = false

M.role_map = {
  user = "user",
  assistant = "assistant",
}

-- Store active workflows
M.active_workflows = {}

-- Store Socket.IO connection handles
M.socketio_connections = {}

-- Error status codes from GitLab Duo specification
M.error_codes = {
  [1] = "Your request was valid but Workflow failed to complete it. Please try again.",
  [2] = "Workflow failed to start.",
  [3] = "Workflow could not use your token to connect to your GitLab instance.",
  [6] = "Workflow could not connect to the Workflow service.",
  [50] = "An error occurred while fetching an authentication token for this workflow.",
  [51] = "GitLab API configuration details are unavailable. Restart your editor and try again.",
  [52] = "Unsupported connection type for Workflow.",
}

-- Status indicators for UI
M.status_icons = {
  CREATED = "🔵",
  RUNNING = "⏳",
  FINISHED = "✅",
  FAILED = "❌",
  STOPPED = "⏹️",
  INPUT_REQUIRED = "❓",
  PLAN_APPROVAL_REQUIRED = "📋",
  TOOL_CALL_APPROVAL_REQUIRED = "🔧",
}

-- Get GitLab LSP client
---@return table|nil
function M.get_gitlab_client()
  for _, client in ipairs(vim.lsp.get_active_clients()) do
    -- Support both gitlab_lsp and gitlab_code_suggestions client names
    if client.name == "gitlab_lsp" or client.name == "gitlab_code_suggestions" then return client end
  end
  return nil
end

---Get webview metadata including HTTP server URL and port
---@return table|nil Array of webview metadata objects with id, title, and uris
function M.get_webview_metadata()
  local client = M.get_gitlab_client()
  if not client then
    Utils.debug("get_webview_metadata: No GitLab LSP client found")
    return nil
  end

  -- Use request_sync to query webview metadata
  local success, result = pcall(function()
    return client.request_sync("$/gitlab/webview-metadata", {}, 5000, vim.api.nvim_get_current_buf())
  end)

  if not success then
    Utils.debug("get_webview_metadata: Request failed: " .. tostring(result))
    return nil
  end

  if not result or not result.result then
    Utils.debug("get_webview_metadata: No result returned")
    return nil
  end

  Utils.debug("get_webview_metadata: Received metadata: " .. vim.inspect(result.result))
  return result.result
end

---Get Socket.IO connection URL for agentic chat webview
---@return string|nil, string|nil URL and CSRF token
function M.get_socketio_url()
  local metadata = M.get_webview_metadata()
  if not metadata then
    Utils.debug("get_socketio_url: No webview metadata available")
    return nil, nil
  end

  -- Find the agentic-duo-chat webview
  for _, webview in ipairs(metadata) do
    if webview.id == "agentic-duo-chat" then
      if not webview.uris or #webview.uris == 0 then
        Utils.debug("get_socketio_url: No URIs found for agentic-duo-chat")
        return nil, nil
      end

      -- Extract the first URI and parse it
      local uri = webview.uris[1]
      Utils.debug("get_socketio_url: Found URI: " .. uri)

      -- Parse URI: http://127.0.0.1:PORT/webview/agentic-duo-chat?_csrf=TOKEN
      local base_url = uri:match("^(http://[^?]+)")
      local csrf_token = uri:match("_csrf=([^&]+)")

      if base_url and csrf_token then
        Utils.debug("get_socketio_url: Base URL: " .. base_url .. ", CSRF: " .. csrf_token)
        return base_url, csrf_token
      else
        Utils.debug("get_socketio_url: Failed to parse URI")
        return nil, nil
      end
    end
  end

  Utils.debug("get_socketio_url: agentic-duo-chat webview not found in metadata")
  return nil, nil
end

---Start Socket.IO client process for agentic chat
---@param workflow_params table Workflow parameters including goal, type, metadata
---@return number|nil, string|nil Job ID if started successfully, temp workflow ID
function M.start_socketio_client(workflow_params)
  -- Get Socket.IO connection URL
  local base_url, csrf_token = M.get_socketio_url()
  if not base_url or not csrf_token then
    Utils.error("Failed to get Socket.IO URL from LSP", { once = true, title = "Avante" })
    return nil, nil
  end

  -- Generate a temporary ID to track the connection
  local temp_id = "avante_temp_" .. os.time() .. "_" .. math.random(1000, 9999)

  -- Get the path to the socketio_agentic_chat_client.js script
  local script_path = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h") .. "/socketio_agentic_chat_client.js"
  
  Utils.debug("Starting Socket.IO client for agentic chat")
  Utils.debug("Base URL: " .. base_url)
  Utils.debug("Script path: " .. script_path)
  Utils.debug("Temp ID: " .. temp_id)

  -- Check if socket.io-client is installed
  local check_cmd = "node -e \"require('socket.io-client')\" 2>&1"
  vim.fn.system(check_cmd)
  if vim.v.shell_error ~= 0 then
    Utils.warn(
      "socket.io-client not installed. Installing via npm...\n" ..
      "Run: npm install -g socket.io-client",
      { once = true, title = "Avante" }
    )
    
    -- Attempt to install locally in the script directory
    local install_cmd = string.format(
      "cd %s && npm install socket.io-client 2>&1",
      vim.fn.shellescape(vim.fn.fnamemodify(script_path, ":h"))
    )
    vim.fn.system(install_cmd)
  end

  -- Convert workflow_params to JSON string
  local workflow_params_json = vim.fn.json_encode(workflow_params)

  -- Start the Socket.IO client process
  local cmd = {
    "node",
    script_path,
    base_url,
    csrf_token,
    workflow_params_json
  }

  local job_id = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data, _)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            -- Parse JSON event from stdout
            local ok, event = pcall(vim.fn.json_decode, line)
            if ok and event then
              M.handle_socketio_event(temp_id, event)
            else
              Utils.debug("Socket.IO: " .. line)
            end
          end
        end
      end
    end,
    on_stderr = function(_, data, _)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            Utils.debug("Socket.IO [stderr]: " .. line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code, _)
      Utils.debug("Socket.IO client exited with code: " .. exit_code)
      M.socketio_connections[temp_id] = nil
    end,
    stdout_buffered = false,
    stderr_buffered = false,
  })

  if job_id > 0 then
    M.socketio_connections[temp_id] = job_id
    Utils.debug("Socket.IO client started with job ID: " .. job_id)
    return job_id, temp_id
  else
    Utils.error("Failed to start Socket.IO client", { once = true, title = "Avante" })
    return nil, nil
  end
end

---Handle events received from Socket.IO client
---@param temp_id string Temporary workflow ID
---@param event table
function M.handle_socketio_event(temp_id, event)
  Utils.debug("Socket.IO event: " .. vim.inspect(event))

  local event_type = event.type

  if event_type == "connected" then
    Utils.info("Connected to GitLab Duo Agentic Chat service", { once = true, title = "Avante" })
  elseif event_type == "workflowStarted" then
    -- Extract the real workflow ID from the event
    local real_workflow_id = event.data and (event.data.workflowId or event.data.workflow_id or event.data.id)
    if real_workflow_id then
      Utils.debug("Workflow started with real ID: " .. real_workflow_id)
      
      -- Move the workflow state from temp_id to real workflow_id
      if M.active_workflows[temp_id] then
        M.active_workflows[real_workflow_id] = M.active_workflows[temp_id]
        M.active_workflows[temp_id] = nil
      end
      
      -- Update connection mapping
      if M.socketio_connections[temp_id] then
        M.socketio_connections[real_workflow_id] = M.socketio_connections[temp_id]
        M.socketio_connections[temp_id] = nil
      end
      
      Utils.info("Agentic Chat workflow started: " .. real_workflow_id, { once = true, title = "Avante" })
    end
  elseif event_type == "workflowCheckpoint" then
    -- Find the workflow ID (could be temp or real)
    local workflow_id = temp_id
    if not M.active_workflows[workflow_id] then
      -- Try to find by checking all workflows
      for id, _ in pairs(M.active_workflows) do
        if M.socketio_connections[id] == M.socketio_connections[temp_id] then
          workflow_id = id
          break
        end
      end
    end
    
    -- Convert Socket.IO event to LSP format and handle it
    M.handle_workflow_message(workflow_id, event.data)
  elseif event_type == "workflowStatus" then
    -- Find the workflow ID
    local workflow_id = temp_id
    for id, _ in pairs(M.active_workflows) do
      if M.socketio_connections[id] == M.socketio_connections[temp_id] then
        workflow_id = id
        break
      end
    end
    
    -- Update workflow status
    if M.active_workflows[workflow_id] then
      M.active_workflows[workflow_id].status = event.status
      Utils.debug("Workflow status updated: " .. tostring(event.status))
    end
  elseif event_type == "workflowError" then
    Utils.error("Workflow error: " .. vim.inspect(event.error), { once = true, title = "Avante" })
    local workflow_id = temp_id
    if M.active_workflows[workflow_id] then
      M.active_workflows[workflow_id].status = "FAILED"
      table.insert(M.active_workflows[workflow_id].errors, event.error)
    end
  elseif event_type == "error" then
    Utils.error("Socket.IO error: " .. event.message, { once = true, title = "Avante" })
  elseif event_type == "disconnected" then
    Utils.warn("Socket.IO disconnected: " .. event.reason, { once = true, title = "Avante" })
  end
end

---Stop Socket.IO client for a workflow
---@param workflow_id string
function M.stop_socketio_client(workflow_id)
  local job_id = M.socketio_connections[workflow_id]
  if job_id then
    Utils.debug("Stopping Socket.IO client for workflow: " .. workflow_id)
    vim.fn.jobstop(job_id)
    M.socketio_connections[workflow_id] = nil
  end
end

---Get git remote URL from the current working directory
---@return string|nil
function M.get_git_remote_url()
  -- Use current working directory instead of buffer's directory
  local cwd = vim.fn.getcwd()
  Utils.debug("get_git_remote_url: Checking directory: " .. cwd)

  -- Use vim.fn.system instead of io.popen for better compatibility
  local cmd = string.format("git -C %s remote get-url origin 2>/dev/null", vim.fn.shellescape(cwd))
  local result = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error

  if exit_code == 0 and result and result ~= "" then
    local url = vim.trim(result)
    Utils.debug("get_git_remote_url: Found remote URL: " .. url)
    return url
  end

  Utils.debug("get_git_remote_url: No remote URL found (exit code: " .. exit_code .. ")")
  return nil
end

---Parse GitLab namespace and project from git remote URL
---@param remote_url string
---@return string|nil namespace
---@return string|nil project
function M.parse_gitlab_remote(remote_url)
  if not remote_url then return nil, nil end

  -- Handle HTTPS URLs: https://gitlab.com/namespace/project.git
  local https_match = remote_url:match("https?://[^/]+/(.+)/([^/]+)%.git$")
  if https_match then
    local parts = vim.split(remote_url:match("https?://[^/]+/(.+)%.git$"), "/")
    if #parts >= 2 then
      local project = parts[#parts]
      table.remove(parts, #parts)
      local namespace = table.concat(parts, "/")
      return namespace, project
    end
  end

  -- Handle SSH URLs: git@gitlab.com:namespace/project.git
  local ssh_match = remote_url:match("git@[^:]+:(.+)%.git$")
  if ssh_match then
    local parts = vim.split(ssh_match, "/")
    if #parts >= 2 then
      local project = parts[#parts]
      table.remove(parts, #parts)
      local namespace = table.concat(parts, "/")
      return namespace, project
    end
  end

  return nil, nil
end

---Get GitLab project path (namespace/project) from current git repository
---@return string|nil
function M.get_current_project_path()
  local remote_url = M.get_git_remote_url()
  if not remote_url then
    Utils.debug("No git remote URL found")
    return nil
  end

  Utils.debug("Git remote URL: " .. remote_url)

  local namespace, project = M.parse_gitlab_remote(remote_url)
  if namespace and project then
    local project_path = namespace .. "/" .. project
    Utils.debug("Detected GitLab project path: " .. project_path)
    return project_path
  end

  Utils.debug("Could not parse GitLab project from remote URL")
  return nil
end

---Get GitLab token and base URL
---@return string|nil, string|nil
function M.get_gitlab_credentials()
  -- Get token from environment variable
  local token = vim.env.GITLAB_TOKEN

  if not token then
    Utils.debug("No GITLAB_TOKEN environment variable found")
    return nil, nil
  end

  Utils.debug("Found GITLAB_TOKEN environment variable")

  -- Get base URL from LSP client settings if available, otherwise use default
  local base_url = "https://gitlab.com"
  local client = M.get_gitlab_client()
  if client and client.config.settings and client.config.settings.gitlab then
    base_url = client.config.settings.gitlab.baseUrl or base_url
  end

  Utils.debug("GitLab base URL: " .. base_url)

  return token, base_url
end

---Query GitLab API to get project information
---@param project_path string The namespace/project path
---@return table|nil Project information with id and namespace
function M.query_gitlab_project(project_path)
  local token, base_url = M.get_gitlab_credentials()

  if not token then
    Utils.debug("No GitLab token available, cannot query API")
    return nil
  end

  if not project_path then
    Utils.debug("No project path provided")
    return nil
  end

  -- URL-encode the project path
  local encoded_path = project_path:gsub("/", "%%2F")
  local api_url = base_url .. "/api/v4/projects/" .. encoded_path

  Utils.debug("Querying GitLab API: " .. api_url)

  -- Use curl to query the API
  local curl_cmd = string.format("curl -s -H 'PRIVATE-TOKEN: %s' '%s'", token, api_url)

  local result = vim.fn.system(curl_cmd)
  local exit_code = vim.v.shell_error

  if exit_code ~= 0 then
    Utils.debug("GitLab API query failed with exit code: " .. exit_code)
    return nil
  end

  -- Parse JSON response
  local ok, project_data = pcall(vim.fn.json_decode, result)
  if not ok or not project_data then
    Utils.debug("Failed to parse GitLab API response")
    return nil
  end

  if project_data.message then
    Utils.debug("GitLab API error: " .. project_data.message)
    return nil
  end

  Utils.debug("Successfully retrieved project info from GitLab API")
  Utils.debug("Project ID: " .. tostring(project_data.id))
  Utils.debug("Namespace ID: " .. tostring(project_data.namespace and project_data.namespace.id))

  return project_data
end

---Get GitLab project ID and namespace ID from current repository
---@return string|nil, string|nil
function M.get_project_ids()
  local project_path = M.get_current_project_path()
  if not project_path then
    Utils.debug("Could not determine project path from git remote")
    return nil, nil
  end

  local project_data = M.query_gitlab_project(project_path)
  if not project_data then
    Utils.debug("Could not query GitLab API for project information")
    return nil, nil
  end

  local project_id = tostring(project_data.id)
  local namespace_id = project_data.namespace and tostring(project_data.namespace.id)

  return project_id, namespace_id
end

---@param workflow_id string
---@param result table
function M.handle_workflow_message(workflow_id, result)
  Utils.debug("handle_workflow_message called for workflow_id: " .. workflow_id)
  Utils.debug("Result full structure: " .. vim.inspect(result))

  -- Check if this is an error response instead of a workflow update
  if result.type == "error" and result.message then
    Utils.error("GitLab Duo error: " .. result.message, { once = true, title = "Avante" })
    Utils.debug("Error response from GitLab: " .. vim.inspect(result))
    return
  end

  if not result or not result.checkpoint then
    Utils.debug("handle_workflow_message: missing checkpoint, result.checkpoint=" .. tostring(result.checkpoint))
    return
  end

  -- Parse the checkpoint
  local ok, checkpoint = pcall(vim.fn.json_decode, result.checkpoint)
  if not ok then
    Utils.error("Failed to parse workflow checkpoint: " .. tostring(checkpoint), { once = true, title = "Avante" })
    return
  end

  local chat_log = checkpoint.channel_values and checkpoint.channel_values.ui_chat_log or {}

  -- Extract workflow status - handle multiple possible field names
  -- Check result first, then checkpoint.channel_values, then checkpoint.metadata
  local workflow_status = result.workflowStatus
    or result.workflow_status
    or result.status
    or (checkpoint.channel_values and checkpoint.channel_values.status)
    or (checkpoint.metadata and checkpoint.metadata.status)
    or (checkpoint.metadata and checkpoint.metadata.workflowStatus)
    or "RUNNING"

  Utils.debug(
    "handle_workflow_message: status="
      .. tostring(workflow_status)
      .. ", chat_log size="
      .. #chat_log
      .. ", errors="
      .. vim.inspect(result.errors or {})
  )

  -- Log all possible status fields for debugging
  Utils.debug("Status field candidates: workflowStatus=" .. tostring(result.workflowStatus)
    .. ", workflow_status=" .. tostring(result.workflow_status)
    .. ", status=" .. tostring(result.status)
    .. ", checkpoint.channel_values.status=" .. tostring(checkpoint.channel_values and checkpoint.channel_values.status)
    .. ", checkpoint.metadata.status=" .. tostring(checkpoint.metadata and checkpoint.metadata.status))

  -- Store workflow state
  M.active_workflows[workflow_id] = {
    status = workflow_status,
    goal = result.workflowGoal or result.workflow_goal or result.goal,
    errors = result.errors or {},
    checkpoint = checkpoint,
    chat_log = chat_log,
  }

  return chat_log
end

---@param tool AvanteLLMTool
---@return table
function M:transform_tool(tool)
  -- GitLab Duo uses its own tool format, we don't need to transform
  return {
    name = tool.name,
    description = tool.get_description and tool.get_description() or tool.description,
    parameters = tool.param.fields,
  }
end

function M:is_disable_stream() return false end

---@return table[]
function M:parse_messages(opts)
  local messages = {}

  for _, message in ipairs(opts.messages) do
    local content = message.content
    if type(content) == "table" then
      -- Extract text content from complex content items
      local text_parts = {}
      for _, item in ipairs(content) do
        if type(item) == "string" then
          table.insert(text_parts, item)
        elseif type(item) == "table" and item.type == "text" then
          table.insert(text_parts, item.text)
        end
      end
      content = table.concat(text_parts, "\n")
    end

    table.insert(messages, {
      role = self.role_map[message.role] or message.role,
      content = content,
    })
  end

  return messages
end

---Get Docker socket path based on OS and container manager
---@return string|nil
function M.get_docker_socket_path()
  -- Check if user has configured a custom Docker socket path
  local custom_socket = vim.env.GITLAB_DOCKER_SOCKET
  if custom_socket then
    Utils.debug("Using custom Docker socket from GITLAB_DOCKER_SOCKET: " .. custom_socket)
    return custom_socket
  end

  -- Auto-detect Docker socket based on OS
  local is_mac = vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1
  local is_linux = vim.fn.has("unix") == 1 and not is_mac
  local home = vim.fn.expand("~")

  if is_mac then
    -- Try common macOS Docker socket locations
    local mac_sockets = {
      home .. "/.colima/default/docker.sock",  -- Colima
      home .. "/.rd/docker.sock",              -- Rancher Desktop
      home .. "/.docker/run/docker.sock",      -- Docker Desktop
      "/var/run/docker.sock",                  -- Standard location
    }

    for _, socket in ipairs(mac_sockets) do
      if vim.fn.filereadable(socket) == 1 then
        Utils.debug("Found Docker socket at: " .. socket)
        return socket
      end
    end
  elseif is_linux then
    -- Try common Linux Docker socket locations
    local linux_sockets = {
      "/var/run/docker.sock",                  -- Standard location
      home .. "/.docker/desktop/docker.sock",  -- Docker Desktop on Linux
    }

    for _, socket in ipairs(linux_sockets) do
      if vim.fn.filereadable(socket) == 1 then
        Utils.debug("Found Docker socket at: " .. socket)
        return socket
      end
    end
  end

  Utils.debug("No Docker socket found")
  return nil
end

---Sync configuration with GitLab LSP
---@param client table LSP client
---@param project_path string|nil Project path (namespace/project)
---@param use_docker boolean|nil Whether to enable Docker support (defaults to false)
function M.sync_lsp_config(client, project_path, use_docker)
  local token, base_url = M.get_gitlab_credentials()

  if not token then
    Utils.debug("Cannot sync LSP config: no token available")
    return
  end

  -- Default to disabled if not explicitly set
  if use_docker == nil then
    use_docker = false
  end

  -- Only attempt to get Docker socket if Docker is enabled
  local docker_socket = ""
  if use_docker then
    docker_socket = M.get_docker_socket_path() or ""
    if docker_socket == "" then
      Utils.warn(
        "Docker is enabled but socket not found. Set GITLAB_DOCKER_SOCKET env var to specify Docker socket path, or disable Docker in provider config.",
        { once = true, title = "Avante" }
      )
      use_docker = false
    else
      Utils.debug("Docker enabled with socket: " .. docker_socket)
    end
  else
    Utils.debug("Docker support is disabled (use_docker = false)")
  end

  -- Build ClientConfig payload similar to VS Code extension
  local config = {
    settings = {
      baseUrl = base_url,
      token = token,
      projectPath = project_path or "",
      duo = {
        enabledWithoutGitlabProject = true,
        workflow = {
          enabled = true,  -- Explicitly enable workflow
          dockerSocket = docker_socket or "",
          useDocker = use_docker,
        },
        agentPlatform = {
          enabled = true, -- Enable agent platform
          connectionType = "streaming",
          defaultNamespace = "",
        },
      },
      featureFlags = {
        duoWorkflow = true,  -- Enable DuoWorkflow client feature flag
        duoWorkflowBinary = false,
        useDuoChatUiForFlow = false,
      },
    },
  }

  Utils.debug("Syncing LSP configuration...")
  Utils.debug("Docker socket: " .. tostring(docker_socket))
  Utils.debug("Use Docker: " .. tostring(use_docker))
  Utils.debug("Config: " .. vim.inspect(config))

  -- Send workspace/didChangeConfiguration notification
  client.notify("workspace/didChangeConfiguration", config)
end

---This function is called by avante.nvim to start the workflow
---@param prompt_opts AvantePromptOptions
---@return AvanteCurlOutput|nil
function M:parse_curl_args(prompt_opts)
  -- Ensure LSP handlers are registered first
  M.setup()

  local client = self.get_gitlab_client()
  if not client then
    Utils.error("GitLab LSP client not found. Please ensure gitlab_lsp is running.", {
      once = true,
      title = "Avante",
    })
    return nil
  end

  local provider_conf, _ = P.parse_config(self)

  -- Get the goal from the last user message
  local goal = ""
  for i = #prompt_opts.messages, 1, -1 do
    if prompt_opts.messages[i].role == "user" then
      local content = prompt_opts.messages[i].content
      if type(content) == "table" then
        for _, item in ipairs(content) do
          if type(item) == "string" then
            goal = item
            break
          elseif type(item) == "table" and item.type == "text" then
            goal = item.text
            break
          end
        end
      else
        goal = content
      end
      break
    end
  end

  if goal == "" then
    Utils.error("No user message found to start workflow", { once = true, title = "Avante" })
    return nil
  end

  -- Build additional context from current buffer and selected files
  local context = {}
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local filename = ""

  if filepath ~= "" and content ~= "" then
    filename = vim.fn.fnamemodify(filepath, ":t")
    table.insert(context, {
      category = "file",
      content = content,
      metadata = {
        file_name = filename,
        file_path = filepath,
      },
    })
  end

  -- Extract selected files from context messages
  -- Selected files are rendered in messages with is_context = true
  for _, message in ipairs(prompt_opts.messages) do
    if message.is_context and message.content then
      -- Parse selected files from the rendered context
      -- Format: <file path="..." language="...">content</file>
      local content_str = message.content

      -- Use pattern matching to find all file blocks
      -- Match pattern: <file path="..." language="...">...</file>
      local start_pos = 1
      while true do
        local file_start, file_end = content_str:find('<file path="[^"]*" language="[^"]*">.-</file>', start_pos)
        if not file_start then break end

        local file_block = content_str:sub(file_start, file_end)

        -- Extract path, language, and content from the file block
        local file_path = file_block:match('<file path="([^"]+)"')
        local file_content = file_block:match('>(.+)</file>$')

        if file_path and file_content then
          local file_name = vim.fn.fnamemodify(file_path, ":t")
          -- Only add if it's not the same as the current buffer
          if file_path ~= filepath then
            table.insert(context, {
              category = "file",
              content = file_content,
              metadata = {
                file_name = file_name,
                file_path = file_path,
              },
            })
            Utils.debug("Added selected file to context: " .. file_path)
          end
        end

        start_pos = file_end + 1
      end
    end
  end

  -- Enhance the goal with file context if available
  if filename ~= "" then
    -- Always include file context to help the agent understand what file is being referenced
    if goal:lower():match("this file") or goal:lower():match("explain") or goal:lower():match("what") then
      goal = goal .. " (file: " .. filename .. ")"
      Utils.debug("Enhanced goal with file context: " .. goal)
    end
  end

  -- Get project IDs - prioritize config values, then auto-detect from git
  local project_id = provider_conf.project_id
  local namespace_id = provider_conf.namespace_id

  -- If no explicit config values, try to auto-detect from git and query GitLab API
  if not project_id or not namespace_id then
    Utils.debug("Attempting to auto-detect project from git repository...")
    local detected_project_id, detected_namespace_id = M.get_project_ids()

    -- Use detected values if config doesn't provide them
    if not project_id and detected_project_id then
      project_id = detected_project_id
      Utils.debug("Using auto-detected project_id: " .. project_id)
    end

    if not namespace_id and detected_namespace_id then
      namespace_id = detected_namespace_id
      Utils.debug("Using auto-detected namespace_id: " .. namespace_id)
    end
  end

  -- Build metadata - only include fields that have values
  local metadata = {
    selectedModelIdentifier = provider_conf.model,
  }

  if project_id then
    metadata.projectId = project_id
    Utils.debug("Using projectId: " .. tostring(project_id))
  else
    Utils.warn(
      "No GitLab project detected. Workflow may fail. Please set project_id in config or ensure you're in a GitLab repository.",
      { once = true, title = "Avante" }
    )
  end

  if namespace_id then
    metadata.namespaceId = namespace_id
    Utils.debug("Using namespaceId: " .. tostring(namespace_id))
  end

  -- Sync configuration with LSP before starting workflow
  -- This is critical - the LSP needs to know about the project and have agent platform enabled
  local project_path = M.get_current_project_path()
  if project_path then
    Utils.debug("Syncing LSP configuration with project path: " .. project_path)
    -- Pass use_docker config from provider configuration (defaults to false)
    local use_docker = provider_conf.use_docker or false
    M.sync_lsp_config(client, project_path, use_docker)
    -- Give LSP a moment to process the configuration
    vim.wait(100)
  end

  -- Prepare workflow parameters for agentic chat
  local workflow_params = {
    goal = goal,
    type = "chat",  -- Important: this is an agentic chat, not a workflow
    metadata = metadata,
    additionalContext = context,
  }

  Utils.debug("Starting GitLab Duo Agentic Chat with goal: " .. goal)
  Utils.debug("Chat params: " .. vim.inspect(workflow_params))

  -- Generate a workflow ID for tracking
  local workflow_id = "avante_workflow_" .. os.time() .. "_" .. math.random(1000, 9999)
  
  -- Store workflow state
  M.active_workflows[workflow_id] = {
    status = "STARTING",
    goal = goal,
    errors = {},
    chat_log = {},
    params = workflow_params,
  }

  Utils.debug("Created workflow: " .. workflow_id)
  Utils.debug("Active workflows: " .. vim.inspect(vim.tbl_keys(M.active_workflows)))

  -- Send startWorkflow notification to LSP
  -- The LSP will handle the workflow execution and send back workflowMessage notifications
  client.notify("$/gitlab/startWorkflow", workflow_params)
  Utils.debug("Sent $/gitlab/startWorkflow notification to LSP")

  -- Return a special marker that tells avante this is an LSP-based provider
  return {
    workflow_id = workflow_id,
    is_lsp_provider = true,
  }
end

---Parse streaming response from GitLab Duo workflow
---@param ctx table
---@param data_stream string
---@param event_state string|nil
---@param opts table
function M:parse_response(ctx, data_stream, event_state, opts)
  -- GitLab Duo sends responses via LSP notifications, not HTTP streams
  -- This function is called by avante's streaming handler but we handle
  -- the actual responses in the LSP notification handler

  if not ctx.workflow_id then
    Utils.debug("parse_response: no workflow_id in context")
    return
  end

  local workflow = M.active_workflows[ctx.workflow_id]
  if not workflow then
    Utils.debug("parse_response: workflow not found for ID: " .. ctx.workflow_id)
    Utils.debug("Active workflows: " .. vim.inspect(vim.tbl_keys(M.active_workflows)))
    return
  end

  -- Socket.IO events should handle all updates now
  -- No need for polling since we're using real-time Socket.IO connection

  Utils.debug(
    "parse_response: workflow status=" .. tostring(workflow.status) .. ", chat_log size=" .. #(workflow.chat_log or {})
  )

  -- Check if there are new messages in the chat log
  local chat_log = workflow.chat_log or {}
  local last_index = ctx.last_chat_index or 0

  if #chat_log > last_index then
    Utils.debug("parse_response: processing " .. (#chat_log - last_index) .. " new messages")
  end

  for i = last_index + 1, #chat_log do
    local msg = chat_log[i]

    if msg.message_type == "agent" then
      -- Agent message - stream the content
      Utils.debug("parse_response: agent message, length=" .. #(msg.content or ""))
      if opts.on_chunk then opts.on_chunk(msg.content) end

      if opts.on_messages_add then
        local history_msg = HistoryMessage:new("assistant", msg.content, {
          state = "generated",
          turn_id = ctx.turn_id,
        })
        opts.on_messages_add({ history_msg })
      end
    elseif msg.message_type == "tool" then
      -- Tool execution message
      local tool_name = msg.tool_info and msg.tool_info.name or "unknown"
      local tool_content = string.format("\n[Tool: %s]\n%s\n", tool_name, msg.content)
      Utils.debug("parse_response: tool message, tool=" .. tool_name)

      if opts.on_chunk then opts.on_chunk(tool_content) end
    elseif msg.message_type == "request" then
      -- Tool approval request
      if msg.tool_info then
        local approval_msg = string.format("\n[Approval Required for: %s]\n%s\n", msg.tool_info.name, msg.content)
        Utils.debug("parse_response: approval request, tool=" .. msg.tool_info.name)
        if opts.on_chunk then opts.on_chunk(approval_msg) end
      end
    end
  end

  ctx.last_chat_index = #chat_log

  -- Check workflow status
  if workflow.status == "FINISHED" then
    Utils.debug("parse_response: workflow FINISHED")
    if opts.on_stop then opts.on_stop({ reason = "complete" }) end
  elseif workflow.status == "FAILED" then
    Utils.debug("parse_response: workflow FAILED, errors=" .. vim.inspect(workflow.errors))
    if opts.on_stop then
      opts.on_stop({
        reason = "error",
        error = { message = table.concat(workflow.errors, "\n") },
      })
    end
  elseif workflow.status == "TOOL_CALL_APPROVAL_REQUIRED" then
    Utils.debug("parse_response: workflow requires tool approval")
    -- Handle tool approval
    M.handle_tool_approval(ctx.workflow_id, chat_log)
  elseif workflow.status == "INPUT_REQUIRED" then
    Utils.debug("parse_response: workflow requires input")
    -- Handle input request with user prompt
    M.handle_input_required(ctx.workflow_id, chat_log)
  elseif workflow.status == "PLAN_APPROVAL_REQUIRED" then
    Utils.debug("parse_response: workflow requires plan approval")
    -- Handle plan approval
    local plan = workflow.checkpoint.channel_values and workflow.checkpoint.channel_values.plan
    M.handle_plan_approval(ctx.workflow_id, plan)
  end
end

---Send workflow event to GitLab LSP
---@param workflow_id string
---@param event_type string 'pause' | 'resume' | 'stop' | 'message'
---@param message table|nil Optional message payload
function M.send_workflow_event(workflow_id, event_type, message)
  local client = M.get_gitlab_client()
  if not client then
    Utils.error("GitLab LSP client not found", { once = true, title = "Avante" })
    return false
  end

  local params = {
    workflowID = workflow_id,
    eventType = event_type,
  }

  if message then
    params.message = message
  end

  Utils.debug(string.format("Sending workflow event: type=%s, workflow_id=%s", event_type, workflow_id))
  client.notify("$/gitlab/sendWorkflowEvent", params)
  return true
end

---Stop a workflow
---@param workflow_id string
function M.stop_workflow(workflow_id)
  Utils.debug("Stopping workflow: " .. workflow_id)
  
  -- Stop Socket.IO client first
  M.stop_socketio_client(workflow_id)
  
  -- Send stop event to LSP
  if M.send_workflow_event(workflow_id, "stop") then
    M.active_workflows[workflow_id] = nil
  end
end

---Pause a workflow
---@param workflow_id string
function M.pause_workflow(workflow_id)
  Utils.debug("Pausing workflow: " .. workflow_id)
  return M.send_workflow_event(workflow_id, "pause")
end

---Resume a workflow
---@param workflow_id string
function M.resume_workflow(workflow_id)
  Utils.debug("Resuming workflow: " .. workflow_id)
  return M.send_workflow_event(workflow_id, "resume")
end

---Send user message to workflow
---@param workflow_id string
---@param message string User's message
---@param correlation_id string|nil Optional correlation ID for responses
function M.send_user_message(workflow_id, message, correlation_id)
  Utils.debug(string.format("Sending user message to workflow %s: %s", workflow_id, message))
  return M.send_workflow_event(workflow_id, "message", {
    correlation_id = correlation_id or "",
    message = message,
  })
end

---Handle tool approval requests
---@param workflow_id string
---@param chat_log table[]
function M.handle_tool_approval(workflow_id, chat_log)
  -- Find the latest approval request
  local approval_request = nil
  for i = #chat_log, 1, -1 do
    if chat_log[i].message_type == "request" then
      approval_request = chat_log[i]
      break
    end
  end

  if not approval_request or not approval_request.tool_info then return end

  local tool_name = approval_request.tool_info.name
  local tool_args = approval_request.tool_info.args or {}
  local correlation_id = approval_request.correlation_id

  -- Prompt user for approval
  vim.schedule(function()
    local choices = { "Approve Once", "Approve for Session", "Reject" }
    local prompt = string.format(
      "Tool Approval Required:\n\nTool: %s\nArgs: %s\n\nDo you want to approve this tool execution?",
      tool_name,
      vim.inspect(tool_args)
    )

    vim.ui.select(choices, {
      prompt = prompt,
      format_item = function(item) return item end,
    }, function(choice)
      local client = M.get_gitlab_client()
      if not client then return end

      if choice == "Approve Once" then
        client.notify("$/gitlab/startWorkflow", {
          goal = "",
          existingWorkflowId = workflow_id,
          toolApproval = {
            userApproved = true,
            toolName = tool_name,
            type = "approve_once",
          },
        })
        Utils.info("Tool approved: " .. tool_name, { once = true, title = "Avante" })
      elseif choice == "Approve for Session" then
        client.notify("$/gitlab/startWorkflow", {
          goal = "",
          existingWorkflowId = workflow_id,
          toolApproval = {
            userApproved = true,
            toolName = tool_name,
            type = "approve-for-session",
          },
        })
        Utils.info("Tool approved for session: " .. tool_name, { once = true, title = "Avante" })
      else
        -- Reject
        client.notify("$/gitlab/startWorkflow", {
          goal = "",
          existingWorkflowId = workflow_id,
          toolApproval = {
            userApproved = false,
            message = "User rejected the tool call",
          },
        })
        Utils.info("Tool rejected: " .. tool_name, { once = true, title = "Avante" })
      end
    end)
  end)
end

---Handle input required requests
---@param workflow_id string
---@param chat_log table[]
function M.handle_input_required(workflow_id, chat_log)
  -- Find the latest request message that needs input
  local input_request = nil
  local correlation_id = nil

  for i = #chat_log, 1, -1 do
    if chat_log[i].message_type == "request" or chat_log[i].message_type == "agent" then
      input_request = chat_log[i]
      correlation_id = chat_log[i].correlation_id
      break
    end
  end

  if not input_request then
    Utils.debug("No input request found in chat log")
    return
  end

  -- Prompt user for input
  vim.schedule(function()
    vim.ui.input({
      prompt = "Agent needs input: ",
      default = "",
    }, function(input)
      if input and input ~= "" then
        M.send_user_message(workflow_id, input, correlation_id)
        Utils.info("Input sent to workflow", { once = true, title = "Avante" })
      else
        Utils.warn("No input provided, workflow may remain blocked", { once = true, title = "Avante" })
      end
    end)
  end)
end

---Handle plan approval requests
---@param workflow_id string
---@param plan table|nil The plan to approve
function M.handle_plan_approval(workflow_id, plan)
  if not plan or not plan.steps then
    Utils.debug("No plan found for approval")
    return
  end

  -- Format plan steps for display
  local plan_lines = { "Agent's Execution Plan:", "" }
  for i, step in ipairs(plan.steps) do
    table.insert(plan_lines, string.format("%d. %s", i, vim.inspect(step)))
  end
  table.insert(plan_lines, "")
  table.insert(plan_lines, "Do you want to approve this plan?")

  local plan_text = table.concat(plan_lines, "\n")

  -- Prompt user for approval
  vim.schedule(function()
    vim.ui.select({ "Approve", "Reject", "Modify" }, {
      prompt = plan_text,
      format_item = function(item) return item end,
    }, function(choice)
      if choice == "Approve" then
        M.send_user_message(workflow_id, "approved", nil)
        Utils.info("Plan approved", { once = true, title = "Avante" })
      elseif choice == "Reject" then
        M.send_user_message(workflow_id, "rejected", nil)
        Utils.info("Plan rejected", { once = true, title = "Avante" })
      elseif choice == "Modify" then
        vim.ui.input({
          prompt = "Modification request: ",
          default = "",
        }, function(modification)
          if modification and modification ~= "" then
            M.send_user_message(workflow_id, "modify: " .. modification, nil)
            Utils.info("Plan modification requested", { once = true, title = "Avante" })
          end
        end)
      end
    end)
  end)
end

---Get error message from error code
---@param error_code number|nil
---@param default_message string|nil
---@return string
function M.get_error_message(error_code, default_message)
  if error_code and M.error_codes[error_code] then
    return M.error_codes[error_code]
  end
  return default_message or "An unknown error occurred with the GitLab Duo workflow."
end

---Handle errors from GitLab Duo
---@param result table
function M.on_error(result)
  if not result then return end

  local error_msg = "GitLab Duo workflow failed"
  local error_code = nil

  if result.body then
    local ok, body = pcall(vim.json.decode, result.body)
    if ok and body then
      if body.error then
        error_msg = body.error
      end
      if body.error_code or body.errorCode or body.code then
        error_code = body.error_code or body.errorCode or body.code
        error_msg = M.get_error_message(error_code, error_msg)
      end
    end
  end

  if error_code then
    error_msg = string.format("[Error %d] %s", error_code, error_msg)
  end

  Utils.error(error_msg, { once = true, title = "Avante" })
end

---Setup LSP handlers for GitLab Duo
---This is called automatically by avante.nvim when the provider is loaded
function M.setup()
  -- Schedule the setup to run after LSP clients are initialized
  vim.schedule(function()
    local client = M.get_gitlab_client()
    if not client then
      -- LSP client not available yet, set up an autocmd to register handlers later
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
          local attached_client = vim.lsp.get_client_by_id(args.data.client_id)
          if attached_client and attached_client.name == "gitlab_lsp" then
            M._register_handlers(attached_client)
            return true -- Remove the autocmd after successful registration
          end
        end,
      })
      return
    end

    M._register_handlers(client)
  end)
end

---Register LSP handlers for GitLab Duo
---@param client table LSP client
function M._register_handlers(client)
  Utils.debug("Registering GitLab Duo LSP handlers...")

  -- Register handler for workflow status updates
  if not client.handlers["$/gitlab/workflowStatusUpdate"] then
    client.handlers["$/gitlab/workflowStatusUpdate"] = function(err, result, ctx)
      Utils.debug("===== WORKFLOW STATUS UPDATE =====")
      Utils.debug("Result: " .. vim.inspect(result))
      
      if err then
        Utils.error("Workflow status update error: " .. vim.inspect(err), {
          once = true,
          title = "Avante",
        })
        return
      end
      
      local workflow_id = result.workflowId or result.workflow_id or result.id
      if not workflow_id then
        -- Try to find the first active workflow
        local active_ids = vim.tbl_keys(M.active_workflows)
        if #active_ids == 1 then
          workflow_id = active_ids[1]
          Utils.debug("Using single active workflow for status update: " .. workflow_id)
        end
      end
      
      if workflow_id and M.active_workflows[workflow_id] then
        local status = result.status or result.workflowStatus
        Utils.debug("Updating workflow " .. workflow_id .. " status to: " .. tostring(status))
        M.active_workflows[workflow_id].status = status
        
        -- Trigger update event
        vim.schedule(function()
          vim.api.nvim_exec_autocmds("User", {
            pattern = "AvanteGitLabDuoWorkflowUpdate",
            data = { workflow_id = workflow_id, status = status }
          })
        end)
      else
        Utils.debug("Received status update for unknown workflow: " .. tostring(workflow_id))
      end
    end
    Utils.debug("Registered handler for $/gitlab/workflowStatusUpdate")
  end

  -- Register handler for workflow messages
  if not client.handlers["$/gitlab/workflowMessage"] then
    client.handlers["$/gitlab/workflowMessage"] = function(err, result, ctx)
      Utils.debug("Received $/gitlab/workflowMessage notification")

      if err then
        Utils.error("GitLab Duo workflow error: " .. vim.inspect(err), {
          once = true,
          title = "Avante",
        })
        return
      end

      Utils.debug("Workflow message result: " .. vim.inspect(result))

      -- Extract workflow ID from the result or context
      -- The workflow ID might be in different places depending on how it's sent
      local workflow_id = result.workflowId or result.workflow_id or result.id

      if not workflow_id then
        Utils.debug("No workflow ID in result, trying to match by goal or using first active workflow")

        -- Try to find it from our active workflows by goal
        local goal = result.workflowGoal or result.workflow_goal or result.goal
        if goal then
          for id, workflow in pairs(M.active_workflows) do
            if workflow.goal == goal then
              workflow_id = id
              Utils.debug("Matched workflow by goal: " .. id)
              break
            end
          end
        end

        -- If still not found and we have only one active workflow, use it
        if not workflow_id then
          local active_ids = vim.tbl_keys(M.active_workflows)
          if #active_ids == 1 then
            workflow_id = active_ids[1]
            Utils.debug("Using single active workflow: " .. workflow_id)
          end
        end
      else
        Utils.debug("Found workflow ID: " .. workflow_id)
      end

      if workflow_id then
        M.handle_workflow_message(workflow_id, result)

        -- Trigger a notification that workflow state has changed
        -- This helps ensure parse_response picks up the changes
        vim.schedule(function()
          vim.api.nvim_exec_autocmds("User", {
            pattern = "AvanteGitLabDuoWorkflowUpdate",
            data = { workflow_id = workflow_id }
          })
        end)
      else
        Utils.debug("Could not determine workflow ID for message")
        Utils.debug("Active workflows: " .. vim.inspect(vim.tbl_keys(M.active_workflows)))
      end
    end
    Utils.debug("Registered handler for $/gitlab/workflowMessage")
  else
    Utils.debug("Handler for $/gitlab/workflowMessage already registered")
  end

  -- Register handler for command execution requests
  if not client.handlers["$/gitlab/runCommand"] then
    client.handlers["$/gitlab/runCommand"] = function(err, params, ctx)
      Utils.debug("Received $/gitlab/runCommand request")

      if err then return { exitCode = 1, output = "Error: " .. vim.inspect(err) } end

      local command = params.command
      local args = params.args or {}

      Utils.debug("Executing command: " .. command .. " " .. vim.inspect(args))

      -- Execute command using Neovim's job API
      local output = {}
      local exit_code = 0

      local job_id = vim.fn.jobstart(vim.list_extend({ command }, args), {
        on_stdout = function(_, data)
          if data then vim.list_extend(output, data) end
        end,
        on_stderr = function(_, data)
          if data then vim.list_extend(output, data) end
        end,
        on_exit = function(_, code) exit_code = code end,
      })

      -- Wait for job to complete
      vim.fn.jobwait({ job_id }, -1)

      Utils.debug("Command completed with exit code: " .. exit_code)

      return {
        exitCode = exit_code,
        output = table.concat(output, "\n"),
      }
    end
    Utils.debug("Registered handler for $/gitlab/runCommand")
  else
    Utils.debug("Handler for $/gitlab/runCommand already registered")
  end

  -- Add catch-all notification logger to see what we're missing
  local original_on_notification = client.handlers["$/progress"]
  vim.lsp.handlers["$/gitlab/"] = function(err, result, ctx, config)
    Utils.debug("===== RECEIVED GITLAB NOTIFICATION =====")
    Utils.debug("Method: " .. tostring(ctx.method))
    Utils.debug("Error: " .. vim.inspect(err))
    Utils.debug("Result: " .. vim.inspect(result))
  end

  Utils.info("GitLab Duo LSP handlers registered", { once = true, title = "Avante" })
end

return M

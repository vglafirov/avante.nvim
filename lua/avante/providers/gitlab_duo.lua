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
  Utils.debug("Result keys: " .. vim.inspect(vim.tbl_keys(result)))

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
  Utils.debug(
    "handle_workflow_message: status="
      .. tostring(result.workflowStatus)
      .. ", chat_log size="
      .. #chat_log
      .. ", errors="
      .. vim.inspect(result.errors or {})
  )

  -- Store workflow state
  M.active_workflows[workflow_id] = {
    status = result.workflowStatus,
    goal = result.workflowGoal,
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

---Sync configuration with GitLab LSP
---@param client table LSP client
---@param project_path string|nil Project path (namespace/project)
function M.sync_lsp_config(client, project_path)
  local token, base_url = M.get_gitlab_credentials()

  if not token then
    Utils.debug("Cannot sync LSP config: no token available")
    return
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
          enabled = true  -- Explicitly enable workflow
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

  -- Build additional context from current buffer
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
    M.sync_lsp_config(client, project_path)
    -- Give LSP a moment to process the configuration
    vim.wait(100)
  end

  -- Start the workflow via LSP request (not notify) to get the workflow ID back
  local workflow_params = {
    goal = goal,
    metadata = metadata,
    additionalContext = context,
  }

  Utils.debug("Starting GitLab Duo workflow with goal: " .. goal)
  Utils.debug("Workflow params: " .. vim.inspect(workflow_params))

  -- Use request to get the workflow ID synchronously
  local success, result = pcall(
    function() return client.request_sync("$/gitlab/startWorkflow", workflow_params, 5000, bufnr) end
  )

  local workflow_id
  if success and result and result.result then
    workflow_id = result.result.workflowId or result.result.workflow_id
    Utils.debug("GitLab Duo workflow started with ID: " .. tostring(workflow_id))
  end

  -- Fallback: generate local ID if GitLab doesn't return one
  if not workflow_id then
    workflow_id = "avante_" .. os.time() .. "_" .. math.random(1000, 9999)
    Utils.debug("Using fallback workflow ID: " .. workflow_id)

    -- Still send the workflow start notification
    client.notify("$/gitlab/startWorkflow", workflow_params)
  end

  -- Store workflow ID for tracking
  M.active_workflows[workflow_id] = {
    status = "RUNNING",
    goal = goal,
    errors = {},
    chat_log = {},
  }

  Utils.debug("Active workflows: " .. vim.inspect(vim.tbl_keys(M.active_workflows)))

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
      local workflow_id = result.workflowId or result.workflow_id
      if not workflow_id then
        Utils.debug("No workflow ID in result, trying to match by goal")
        -- Try to find it from our active workflows
        for id, workflow in pairs(M.active_workflows) do
          if workflow.goal == result.workflowGoal then
            workflow_id = id
            Utils.debug("Matched workflow by goal: " .. id)
            break
          end
        end
      else
        Utils.debug("Found workflow ID: " .. workflow_id)
      end

      if workflow_id then
        M.handle_workflow_message(workflow_id, result)
      else
        Utils.debug("Could not determine workflow ID for message")
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

  Utils.info("GitLab Duo LSP handlers registered", { once = true, title = "Avante" })
end

return M

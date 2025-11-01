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

-- Get GitLab LSP client
---@return table|nil
function M.get_gitlab_client()
  for _, client in ipairs(vim.lsp.get_active_clients()) do
    if client.name == "gitlab_lsp" then return client end
  end
  return nil
end

---@param workflow_id string
---@param chat_log table[]
function M.handle_workflow_message(workflow_id, result)
  if not result or not result.checkpoint then return end

  -- Parse the checkpoint
  local ok, checkpoint = pcall(vim.fn.json_decode, result.checkpoint)
  if not ok then
    Utils.error("Failed to parse workflow checkpoint", { once = true, title = "Avante" })
    return
  end

  local chat_log = checkpoint.channel_values and checkpoint.channel_values.ui_chat_log or {}

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

  if filepath ~= "" and content ~= "" then
    table.insert(context, {
      category = "file",
      content = content,
      metadata = {
        file_name = vim.fn.fnamemodify(filepath, ":t"),
        file_path = filepath,
      },
    })
  end

  -- Start the workflow via LSP request (not notify) to get the workflow ID back
  local workflow_params = {
    goal = goal,
    metadata = {
      projectId = provider_conf.project_id,
      namespaceId = provider_conf.namespace_id,
      selectedModelIdentifier = provider_conf.model,
    },
    additionalContext = context,
  }

  Utils.debug("Starting GitLab Duo workflow with goal: " .. goal)

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
    -- Handle input request
    if opts.on_stop then
      opts.on_stop({
        reason = "error",
        error = "Workflow requires additional input",
      })
    end
  end
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
  local correlation_id = approval_request.correlation_id

  -- Auto-approve for now (could be made configurable)
  local client = M.get_gitlab_client()
  if client then
    client.notify("$/gitlab/startWorkflow", {
      goal = "",
      existingWorkflowId = workflow_id,
      toolApproval = {
        userApproved = true,
        toolName = tool_name,
        type = "approve_once",
      },
    })
  end
end

---Handle errors from GitLab Duo
---@param result table
function M.on_error(result)
  if not result then return end

  local error_msg = "GitLab Duo workflow failed"
  if result.body then
    local ok, body = pcall(vim.json.decode, result.body)
    if ok and body and body.error then error_msg = body.error end
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

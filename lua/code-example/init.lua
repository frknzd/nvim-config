local M = {}

local defaults = {
  command = nil,
  endpoint = nil,
  model = "unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL",
  model_size_gb = 2.78,
  context_size = 8192,
  reasoning_budget = 512,
  reasoning_budget_message = "Conclude briefly and provide the final answer now.",
  max_output_tokens = nil,
  startup_timeout = 300,
  idle_timeout = 600,
  context_radius = 35,
  definition_radius = 45,
  max_tool_rounds = 4,
  max_tool_calls = 8,
  max_tool_results = 40,
  max_tool_lines = 160,
  max_tool_output_chars = 6000,
}

local opts
local active_cancel

local function prompt(context)
  local subject = context.selection and "the selected code" or ("`%s`"):format(context.symbol)
  local sections = {
    ("The user wants to understand %s in %s. Produce a practical, accurate annotated example."):format(
      subject,
      context.filetype
    ),
    table.concat({
      "Return Markdown only. Start with a one-sentence identification of the construct, then one fenced code",
      "example in the correct language. Annotate important lines using short comments inside the code. Follow with",
      "at most four concise notes. Do not invent APIs; mention uncertainty explicitly.",
    }, " "),
  }
  if context.hover and context.hover ~= "" then
    sections[#sections + 1] = "LSP hover information:\n" .. context.hover
  end
  if context.selection then
    sections[#sections + 1] = ("Selected code:\n```%s\n%s\n```"):format(context.filetype, context.selection)
  end
  sections[#sections + 1] = ("Current file `%s`, starting at line %d:\n```%s\n%s\n```"):format(
    context.filename,
    context.current_line,
    context.filetype,
    context.current
  )
  if context.definition then
    sections[#sections + 1] = ("Definition source `%s`, starting at line %d:\n```%s\n%s\n```"):format(
      context.definition.filename,
      context.definition.first_line,
      context.filetype,
      context.definition.text
    )
  end
  return table.concat(sections, "\n\n")
end

local function visual_selection()
  local mode = vim.fn.mode(1)
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil
  end
  local ok, lines = pcall(vim.fn.getregion, vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })
  if not ok or not lines or #lines == 0 then
    return nil
  end
  return table.concat(lines, "\n")
end

local function fail(view, message)
  view:set_content(("# Code Example unavailable\n\n%s\n\nPress `q` to close or `r` to retry."):format(message))
  view:status("Failed", "error")
  vim.notify(message, vim.log.levels.WARN, { title = "Code Example" })
end

local function show_server_log(view, status, lines)
  if not view:is_valid() then
    return
  end
  view:status(status, "busy")
  view:set_thinking(status .. "…")
  local content = {
    "# Starting local model",
    "",
    ("Model: `%s`"):format(opts.model),
    "",
    "Recent llama.cpp output:",
    "",
  }
  if not lines or #lines == 0 then
    content[#content + 1] = "    Waiting for llama.cpp output…"
  else
    local first = math.max(1, #lines - 29)
    for index = first, #lines do
      content[#content + 1] = "    " .. lines[index]
    end
  end
  content[#content + 1] = ""
  content[#content + 1] = "Press `q` to close or `r` to restart."
  view:set_content(table.concat(content, "\n"))
  vim.api.nvim_win_set_cursor(view.win, { vim.api.nvim_buf_line_count(view.buf), 0 })
end

local function tool_label(call)
  local fn = call["function"] or {}
  local arguments = type(fn.arguments) == "string" and fn.arguments or "{}"
  if #arguments > 240 then
    arguments = arguments:sub(1, 237) .. "…"
  end
  return ("### Tool call: `%s`\n\nArguments: `%s`"):format(fn.name or "unknown", arguments)
end

local function run_agent(view, url, messages, tool_session, generation, state)
  if not view:is_valid() or view.generation ~= generation then
    return
  end
  view:status("", "busy", true)
  local payload = {
    model = opts.model,
    stream = true,
    temperature = 0.2,
    messages = messages,
    tools = require("code-example.tools").schemas(),
    tool_choice = state.rounds == 0 and "required" or "auto",
  }
  if opts.max_output_tokens then
    payload.max_tokens = opts.max_output_tokens
  end
  active_cancel = require("code-example.request").start(url, payload, {
    on_chunk = function(chunk)
      if view.generation == generation then
        view:append(chunk)
      end
    end,
    on_reasoning = function(chunk)
      if view.generation == generation then
        view:append_thinking(chunk)
      end
    end,
    on_done = function(result)
      active_cancel = nil
      if not view:is_valid() or view.generation ~= generation then
        return
      end
      local calls = result.tool_calls or {}
      if #calls == 0 then
        require("code-example.server").idle(opts.idle_timeout)
        view:status("Complete", "done")
        if view.content == "" then
          local reason = result.finish_reason == "length" and "The model exhausted the available context"
            or "The model stopped"
          view:set_content(("_%s without producing a final answer. Press `r` to try again._"):format(reason))
        end
        return
      end

      state.rounds = state.rounds + 1
      if state.rounds > opts.max_tool_rounds or state.calls + #calls > opts.max_tool_calls then
        fail(view, "The model exceeded the configured tool-call limit.")
        require("code-example.server").idle(opts.idle_timeout)
        return
      end
      state.calls = state.calls + #calls
      view:status("Inspecting sources", "busy")
      local assistant_message = { role = "assistant", tool_calls = calls }
      if result.content ~= "" then
        assistant_message.content = result.content
      end
      if result.reasoning_content ~= "" then
        assistant_message.reasoning_content = result.reasoning_content
      end
      messages[#messages + 1] = assistant_message

      local index = 1
      local function execute_next()
        if not view:is_valid() or view.generation ~= generation then
          return
        end
        local call = calls[index]
        if not call then
          view:append_thinking("\n\nThinking with the inspected context…\n\n")
          view:status("Generating", "busy")
          run_agent(view, url, messages, tool_session, generation, state)
          return
        end
        call.id = call.id or ("code_example_tool_%d_%d"):format(state.rounds, index)
        local tool_name = call["function"] and call["function"].name or "unknown"
        view:status("", "busy", true, tool_name)
        view:append_thinking("\n\n" .. tool_label(call) .. "\n")
        require("code-example.tools").execute(tool_session, call, function(tool_result)
          if not view:is_valid() or view.generation ~= generation then
            return
          end
          tool_result = tostring(tool_result or "No result")
          if #tool_result > opts.max_tool_output_chars then
            tool_result = tool_result:sub(1, opts.max_tool_output_chars - 20) .. "\n…result truncated…"
          end
          local preview = #tool_result > 700 and tool_result:sub(1, 697) .. "…" or tool_result
          view:append_thinking("\n\nTool result:\n\n" .. preview .. "\n")
          messages[#messages + 1] = {
            role = "tool",
            tool_call_id = call.id,
            content = tool_result,
          }
          index = index + 1
          execute_next()
        end)
      end
      execute_next()
    end,
    on_error = function(request_err)
      active_cancel = nil
      require("code-example.server").idle(opts.idle_timeout)
      if view:is_valid() and view.generation == generation then
        fail(view, request_err)
      end
    end,
  })
end

local function generate(view, source)
  view.generation = (view.generation or 0) + 1
  local generation = view.generation
  if active_cancel then
    active_cancel()
    active_cancel = nil
  end
  view:set_content("Preparing context…\n\nPress `q` to close or `r` to regenerate.")
  view:set_thinking("Waiting for LSP context…")
  view:status("Inspecting LSP context", "busy")
  require("code-example.context").collect(source, opts, function(context, err)
    if not view:is_valid() or view.generation ~= generation then
      return
    end
    if err then
      fail(view, err)
      return
    end
    show_server_log(view, "Starting local model")
    local awaiting_server = true
    require("code-example.server").ensure(opts, function(status, lines)
      if awaiting_server and view.generation == generation then
        show_server_log(view, status, lines)
      end
    end, function(url, server_err)
      awaiting_server = false
      if not view:is_valid() or view.generation ~= generation then
        return
      end
      if server_err then
        fail(view, server_err)
        return
      end
      view:set_content("")
      view:set_thinking("Thinking…\n\n")
      view:status("Generating", "busy")
      local messages = {
        {
          role = "system",
          content = table.concat({
            "You are a precise coding teacher. Prefer compilable, idiomatic examples.",
            "Reason directly: identify the construct, verify the example, then answer without revisiting decisions.",
            "Use the provided tools when LSP or source evidence would improve accuracy; do not guess APIs.",
          }, " "),
        },
        { role = "user", content = prompt(context) },
      }
      local tool_session = require("code-example.tools").new(source, context, opts)
      run_agent(view, url, messages, tool_session, generation, { rounds = 0, calls = 0 })
    end)
  end)
end

function M.show()
  local selection = visual_selection()
  local source = {
    bufnr = vim.api.nvim_get_current_buf(),
    winid = vim.api.nvim_get_current_win(),
    cursor = vim.api.nvim_win_get_cursor(0),
    symbol = vim.fn.expand("<cword>"),
    selection = selection,
  }
  local view = require("code-example.ui").open("Usage")
  view.on_cancel = function()
    if active_cancel then
      active_cancel()
      active_cancel = nil
    end
    if require("code-example.server").is_starting() then
      require("code-example.server").stop()
    end
    require("code-example.server").idle(opts.idle_timeout)
  end
  view.on_retry = function()
    generate(view, source)
  end
  generate(view, source)
end

function M.setup(user_opts)
  opts = vim.tbl_deep_extend("force", defaults, user_opts or {})
  vim.api.nvim_create_user_command(
    "CodeExample",
    M.show,
    { desc = "Generate an annotated example for the symbol under cursor" }
  )
  vim.api.nvim_create_user_command("CodeExampleStop", function()
    if active_cancel then
      active_cancel()
      active_cancel = nil
    end
    require("code-example.server").stop()
    vim.notify("Stopped the managed code-example server", vim.log.levels.INFO)
  end, { desc = "Stop the managed code-example server" })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      require("code-example.server").stop()
    end,
  })
end

return M

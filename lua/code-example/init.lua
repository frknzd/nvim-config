local M = {}

local defaults = {
  command = nil,
  endpoint = nil,
  model = "unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL",
  model_size_gb = 2.78,
  context_size = 8192,
  reasoning_budget = 512,
  reasoning_budget_message = "Conclude briefly and provide the final answer now.",
  reasoning_effort = "low",
  max_output_tokens = nil,
  startup_timeout = 300,
  idle_timeout = 600,
  context_radius = 35,
  definition_radius = 45,
  max_tool_rounds = nil,
  max_tool_calls = nil,
  max_tool_results = 40,
  max_search_results = 8,
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
  if context.diagnostics and #context.diagnostics > 0 then
    sections[#sections + 1] = "LSP diagnostics in this range:\n" .. table.concat(context.diagnostics, "\n")
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

local function estimate_tokens(str)
  if type(str) ~= "string" or str == "" then
    return 0
  end
  return math.ceil(#str / 4)
end

local function message_tokens(message)
  local total = 8
  total = total + estimate_tokens(message.content)
  total = total + estimate_tokens(message.reasoning_content)
  if message.tool_calls then
    for _, call in ipairs(message.tool_calls) do
      local ok, encoded = pcall(vim.json.encode, call)
      total = total + estimate_tokens(ok and encoded or nil)
    end
  end
  return total
end

local function messages_tokens(messages)
  local total = 0
  for _, message in ipairs(messages) do
    total = total + message_tokens(message)
  end
  return total
end

local cached_tools_tokens
local function tools_tokens()
  if not cached_tools_tokens then
    local ok, encoded = pcall(vim.json.encode, require("code-example.tools").schemas())
    cached_tools_tokens = estimate_tokens(ok and encoded or nil)
  end
  return cached_tools_tokens
end

local function prompt_budget()
  local reserved = (opts.max_output_tokens or 1024) + (opts.reasoning_budget or 0) + 256
  return math.max(512, opts.context_size - reserved)
end

-- Removes the oldest assistant/tool-result round (messages[3] onward), returning a
-- short note per dropped tool call so the model keeps a trace of what it already tried.
local function compact_round(messages)
  if #messages <= 2 then
    return nil
  end
  local assistant_index = 3
  local assistant = messages[assistant_index]
  if not assistant or assistant.role ~= "assistant" then
    return nil
  end
  local notes = {}
  for _, call in ipairs(assistant.tool_calls or {}) do
    notes[#notes + 1] = { id = call.id, name = call["function"] and call["function"].name or "tool" }
  end
  local remove_count = 1
  local index = assistant_index + 1
  while messages[index] and messages[index].role == "tool" do
    for _, note in ipairs(notes) do
      if note.id == messages[index].tool_call_id then
        note.result = messages[index].content
      end
    end
    remove_count = remove_count + 1
    index = index + 1
  end
  for _ = 1, remove_count do
    table.remove(messages, assistant_index)
  end
  return notes
end

local function summarize_round(notes)
  local lines = {}
  for _, note in ipairs(notes) do
    local result = (note.result or ""):gsub("%s+", " ")
    if #result > 160 then
      result = result:sub(1, 157) .. "…"
    end
    lines[#lines + 1] = ("- %s: %s"):format(note.name, result)
  end
  return lines
end

local function apply_compaction(messages, state)
  if #state.compaction_notes == 0 then
    return
  end
  messages[2].content = state.original_user_content
    .. "\n\nEarlier tool findings, condensed to fit the context window:\n"
    .. table.concat(state.compaction_notes, "\n")
end

-- Drops the oldest tool rounds until the estimated prompt fits the model's context window.
local function compact_to_budget(messages, state)
  local budget = prompt_budget()
  local changed = false
  local guard = 0
  while messages_tokens(messages) + tools_tokens() > budget and #messages > 2 and guard < 50 do
    guard = guard + 1
    local notes = compact_round(messages)
    if not notes then
      break
    end
    vim.list_extend(state.compaction_notes, summarize_round(notes))
    changed = true
  end
  if changed then
    apply_compaction(messages, state)
  end
  return changed
end

-- Unconditionally drops every tool round, for a last-ditch retry after the model already
-- exhausted the context without producing an answer.
local function compact_all_rounds(messages, state)
  local changed = false
  while true do
    local notes = compact_round(messages)
    if not notes then
      break
    end
    vim.list_extend(state.compaction_notes, summarize_round(notes))
    changed = true
  end
  if changed then
    apply_compaction(messages, state)
  end
  return changed
end

local function run_agent(view, url, messages, tool_session, generation, state)
  if not view:is_valid() or view.generation ~= generation then
    return
  end
  if compact_to_budget(messages, state) then
    view:append_thinking("\n\n_Context nearing the limit — condensed earlier tool results to keep going…_\n")
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
  if opts.reasoning_effort then
    payload.reasoning_effort = opts.reasoning_effort
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
        local exhausted = result.finish_reason == "length" and result.content == ""
        if exhausted and not state.length_retry_used and #messages > 2 then
          state.length_retry_used = true
          if compact_all_rounds(messages, state) then
            view:append_thinking(
              "\n\n_Ran out of context before answering — condensing tool history and retrying…_\n"
            )
            view:status("Retrying with condensed context", "busy")
            run_agent(view, url, messages, tool_session, generation, state)
            return
          end
        end
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
      local over_rounds = opts.max_tool_rounds and state.rounds > opts.max_tool_rounds
      local over_calls = opts.max_tool_calls and state.calls + #calls > opts.max_tool_calls
      if over_rounds or over_calls then
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

local function stop_generation(view)
  if not active_cancel then
    return
  end
  view.generation = (view.generation or 0) + 1
  active_cancel()
  active_cancel = nil
  require("code-example.server").idle(opts.idle_timeout)
  if not view:is_valid() then
    return
  end
  view:status("Stopped", "stopped")
  if view.content == "" then
    view:set_content("_Stopped before producing a response. Press `r` to resend or `q` to close._")
  end
end

local function generate(view, source)
  view.generation = (view.generation or 0) + 1
  local generation = view.generation
  if active_cancel then
    active_cancel()
    active_cancel = nil
  end
  view:set_auto_resize(false)
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
      view:set_auto_resize(true)
      view:set_content("")
      view:set_thinking("")
      view:status("Generating", "busy")
      local messages = {
        {
          role = "system",
          content = table.concat({
            "You are a precise coding teacher. Prefer compilable, idiomatic examples.",
            "Reason directly: identify the construct, verify the example, then answer without revisiting decisions.",
            "Use the provided tools when LSP, source, or web evidence would improve accuracy; do not guess APIs.",
            "Prefer LSP and source tools for anything local to the project; use web_search only for external",
            "documentation, API references, or facts the project cannot answer. When a search snippet is not",
            "enough, use web_fetch on the most relevant result to read the full page. If LSP diagnostics are",
            "reported for the code in view, account for them instead of ignoring them. If a tool call fails or",
            "times out, do not retry it more than once; continue with whatever evidence you already have.",
          }, " "),
        },
        { role = "user", content = prompt(context) },
      }
      local tool_session = require("code-example.tools").new(source, context, opts)
      run_agent(view, url, messages, tool_session, generation, {
        rounds = 0,
        calls = 0,
        compaction_notes = {},
        original_user_content = messages[2].content,
      })
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
  local view = require("code-example.ui").open("+== CodeExample ==+")
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
  view.on_stop = function()
    stop_generation(view)
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

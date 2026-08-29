local M = {}

local defaults = {
  command = nil,
  endpoint = nil,
  model = "mlx-community/Qwen3.5-9B-4bit",
  model_size_gb = 5.98,
  context_size = 32768,
  enable_thinking = false,
  max_output_tokens = 8192,
  max_tool_rounds = 3,
  max_web_calls = 2,
  startup_timeout = 300,
  idle_timeout = 600,
  context_radius = 35,
  definition_radius = 45,
  max_tool_results = 40,
  max_search_results = 8,
  search_context_lines = 8,
  max_tool_lines = 160,
  max_tool_output_chars = 6000,
}

local opts
local active_cancel

local function prompt(context)
  local subject = context.selection and "the selected code" or ("`%s`"):format(context.symbol)
  local sections = {
    ("Write practical documentation for %s in %s. Begin the documentation now."):format(subject, context.filetype),
    [[Write clear, concise Markdown and organize it in the way that best fits the construct. Explain its practical contract where relevant: parameters, which values are required or optional, defaults, accepted types or shapes, return values, side effects, errors, and constraints. Use simple lists rather than Markdown tables.

Include enough small, realistic examples to make the important usage patterns clear; do not target a fixed number. Ground them in the available evidence and show exact expected output when it is short and deterministic, using an `Expected output:` label and a fenced text block. Omit unsupported or irrelevant details and do not invent behavior. If this is not a reusable API, explain its actual role and show it in context instead of forcing usage examples.

The evidence below is normally sufficient. Read it, then write the documentation.]],
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
  view:set_markdown_rendering(true)
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
    "Recent mlx-lm output:",
    "",
  }
  if not lines or #lines == 0 then
    content[#content + 1] = "    Waiting for mlx-lm output…"
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

local function tool_added_evidence(result)
  local normalized = vim.trim(tostring(result or "")):lower()
  if normalized == "" or normalized == "no result" then
    return false
  end
  return not normalized:match("^no .- found")
    and not normalized:match("^no matches")
    and not normalized:match("^duplicate tool call blocked")
    and not normalized:match("^tool call blocked")
    and not normalized:match(" failed:")
    and not normalized:match("^access denied:")
    and not normalized:match(" requires ")
end

local function estimate_tokens(str)
  if type(str) ~= "string" or str == "" then
    return 0
  end
  -- Deliberately pessimistic: URL- and code-heavy tool output tokenizes worse than prose,
  -- and undercounting here is what lets a request past compaction still overflow the
  -- server's context window and come back as a 400.
  return math.ceil(#str / 3)
end

local function message_tokens(message)
  local total = 24
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
  local reserved = (opts.max_output_tokens or 1024) + 512
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
  -- Once the round budget is spent the tools come off the request entirely, so the model has
  -- nothing left to do but write the answer from the evidence it already collected.
  local budget_spent = state.rounds >= (opts.max_tool_rounds or 3)
  if budget_spent and not state.final_pass then
    state.final_pass = true
    messages[#messages + 1] = {
      role = "user",
      content = "Stop investigating; the tool budget is spent. Write the documentation now from the evidence "
        .. "already gathered, and say plainly which parts you could not verify.",
    }
    view:append_thinking("\n\n_Tool budget spent — writing the answer from the evidence gathered so far…_\n")
  end
  local available_tools = budget_spent and {} or require("code-example.tools").schemas(state.disabled_tools)
  local payload = {
    model = opts.model,
    stream = true,
    temperature = 0.2,
    messages = messages,
  }
  -- An empty Lua table encodes as a JSON object rather than an array, which mlx-lm rejects,
  -- so drop the key entirely rather than sending `"tools": {}` on the final pass.
  if #available_tools > 0 then
    payload.tools = available_tools
    payload.tool_choice = "auto"
  else
    payload.tool_choice = "none"
  end
  if opts.max_output_tokens then
    payload.max_tokens = opts.max_output_tokens
  end
  if opts.enable_thinking ~= nil then
    payload.chat_template_kwargs = { enable_thinking = opts.enable_thinking }
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
        view:set_markdown_rendering(true)
        view:status("Complete", "done")
        if view.content == "" then
          local reason = result.finish_reason == "length" and "The model exhausted the available context"
            or "The model stopped"
          view:set_content(("_%s without producing a final answer. Press `r` to try again._"):format(reason))
        end
        return
      end

      state.rounds = state.rounds + 1
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
        local arguments = call["function"] and call["function"].arguments or "{}"
        view:status("", "busy", true)
        view:tool_used(tool_name, arguments)
        view:append_thinking("\n\n" .. tool_label(call) .. "\n")
        local signature = tool_name .. "\0" .. arguments
        local duplicate = state.tool_calls_seen[signature]
        state.tool_calls_seen[signature] = true
        local call_blocked = state.disabled_tools[tool_name]
        local web_exhausted = false
        if tool_name:match("^web_") then
          state.web_calls = state.web_calls + 1
          -- A web search that returns snippets still counts as evidence, so the failure
          -- tracking below never disables these; a hard call budget is what stops the model
          -- from spending a whole session re-searching the same external docs.
          if state.web_calls > (opts.max_web_calls or 2) then
            web_exhausted = true
            state.disabled_tools.web_search = true
            state.disabled_tools.web_fetch = true
          end
        end

        local function complete(tool_result)
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
          if tool_added_evidence(tool_result) then
            state.tool_failures[tool_name] = 0
          else
            local failures = (state.tool_failures[tool_name] or 0) + 1
            state.tool_failures[tool_name] = failures
            if failures >= 2 then
              state.disabled_tools[tool_name] = true
            end
          end
          index = index + 1
          execute_next()
        end

        if web_exhausted then
          complete(
            "Web budget spent. The web tools are now unavailable. Answer from the local source, LSP, and file "
              .. "evidence you already have."
          )
        elseif call_blocked then
          complete("Tool call blocked because this tool repeatedly produced no useful evidence. Try another tool.")
        elseif duplicate then
          complete(
            "Duplicate tool call blocked. This exact call already ran and produced no new evidence. "
              .. "Use the earlier result or change strategy."
          )
        else
          state.calls = state.calls + 1
          require("code-example.tools").execute(tool_session, call, complete)
        end
      end
      execute_next()
    end,
    on_error = function(request_err)
      active_cancel = nil
      if not view:is_valid() or view.generation ~= generation then
        return
      end
      if not state.error_retry_used and #messages > 2 then
        state.error_retry_used = true
        if compact_all_rounds(messages, state) then
          view:append_thinking(
            ("\n\n_Request failed (%s) — condensing tool history and retrying…_\n"):format(request_err)
          )
          view:status("Retrying with condensed context", "busy")
          run_agent(view, url, messages, tool_session, generation, state)
          return
        end
      end
      require("code-example.server").idle(opts.idle_timeout)
      fail(view, request_err)
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
  view:set_markdown_rendering(true)
  if view.content == "" then
    view:set_content("_Stopped before producing a response. Press `r` to resend or `q` to close._")
  end
end

local function generate(view, source)
  view.generation = (view.generation or 0) + 1
  view:reset_tools()
  view:set_markdown_rendering(false)
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
            "You write concise, Rustdoc-style documentation for the code under the cursor.",
            "Start writing the documentation immediately. The supplied source, hover text, and diagnostics are",
            "normally enough on their own. Never open with a plan, a restatement of the task, or a narration of",
            "what you are about to check; the first thing you emit is the documentation itself.",
            ("You may take at most %d tool rounds for the entire answer, and most answers should take none."):format(
              opts.max_tool_rounds or 3
            ),
            "Call a tool only to obtain one specific fact you must state and cannot see. Prefer local evidence:",
            "lsp_references for real call sites, source_outline before guessing an unfamiliar type's method names.",
            "Group related searches into a single call. Never re-request hover or definition data already supplied,",
            "and never repeat an identical call. When a search returns nothing useful, stop searching and write the",
            "documentation from what you have, saying plainly which part is unverified.",
            ("The web tools are a last resort, capped at %d calls."):format(opts.max_web_calls or 2),
            "Two empty web searches mean the answer is not on the web, so fall back to the local source instead of",
            "searching again.",
            "Explain the callable contract: required arguments, optional arguments, defaults, return values, side",
            "effects, errors, and important constraints. Teach usage through compilable, idiomatic examples grounded",
            "in the supplied evidence. Use headings, paragraphs, bullet lists, and fenced code blocks only; never use",
            "Markdown tables. For short deterministic examples, include their exact expected output in a fenced text",
            "block. Never invent behavior or APIs; state uncertainty instead.",
          }, " "),
        },
        { role = "user", content = prompt(context) },
      }
      local tool_session = require("code-example.tools").new(source, context, opts)
      run_agent(view, url, messages, tool_session, generation, {
        rounds = 0,
        calls = 0,
        web_calls = 0,
        compaction_notes = {},
        original_user_content = messages[2].content,
        tool_calls_seen = {},
        tool_failures = {},
        disabled_tools = {},
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

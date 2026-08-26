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
}

local opts
local active_cancel

local function prompt(context)
  local sections = {
    ("The user wants to understand `%s` in %s. Produce a practical, accurate annotated example."):format(
      context.symbol,
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
      local payload = {
        model = opts.model,
        stream = true,
        temperature = 0.2,
        messages = {
          {
            role = "system",
            content = table.concat({
              "You are a precise coding teacher. Prefer compilable, idiomatic examples.",
              "Reason directly: identify the construct, verify the example, then answer without revisiting decisions.",
            }, " "),
          },
          { role = "user", content = prompt(context) },
        },
      }
      if opts.max_output_tokens then
        payload.max_tokens = opts.max_output_tokens
      end
      active_cancel = require("code-example.request").start(url, payload, {
        on_chunk = function(chunk)
          view:append(chunk)
        end,
        on_reasoning = function(chunk)
          view:append_thinking(chunk)
        end,
        on_done = function(finish_reason)
          active_cancel = nil
          require("code-example.server").idle(opts.idle_timeout)
          if view:is_valid() then
            view:status("Complete", "done")
            if view.content == "" then
              local reason = finish_reason == "length" and "The model exhausted the available context"
                or "The model stopped"
              view:set_content(("_%s without producing a final answer. Press `r` to try again._"):format(reason))
            end
          end
        end,
        on_error = function(request_err)
          active_cancel = nil
          require("code-example.server").idle(opts.idle_timeout)
          if view:is_valid() then
            fail(view, request_err)
          end
        end,
      })
    end)
  end)
end

function M.show()
  local source = {
    bufnr = vim.api.nvim_get_current_buf(),
    winid = vim.api.nvim_get_current_win(),
    cursor = vim.api.nvim_win_get_cursor(0),
    symbol = vim.fn.expand("<cword>"),
  }
  local view = require("code-example.ui").open("Code Example · " .. source.symbol)
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

local M = {}

local function append_tool_calls(parser, deltas)
  if type(deltas) ~= "table" then
    return
  end
  for _, delta in ipairs(deltas) do
    local index = delta.index or 0
    local call = parser.tool_calls[index] or { type = "function", ["function"] = { name = "", arguments = "" } }
    parser.tool_calls[index] = call
    if type(delta.id) == "string" then
      call.id = (call.id or "") .. delta.id
    end
    if type(delta.type) == "string" then
      call.type = delta.type
    end
    if type(delta["function"]) == "table" then
      local fn = delta["function"]
      if type(fn.name) == "string" then
        call["function"].name = call["function"].name .. fn.name
      end
      if type(fn.arguments) == "string" then
        call["function"].arguments = call["function"].arguments .. fn.arguments
      end
    end
  end
end

local function completed_tool_calls(parser)
  local calls = {}
  for _, index in ipairs(vim.tbl_keys(parser.tool_calls)) do
    calls[#calls + 1] = { index = tonumber(index), call = parser.tool_calls[index] }
  end
  table.sort(calls, function(a, b)
    return a.index < b.index
  end)
  return vim.tbl_map(function(item)
    return item.call
  end, calls)
end

local function feed_sse(parser, chunk)
  parser.pending = parser.pending .. (chunk or "")
  while true do
    local newline = parser.pending:find("\n", 1, true)
    if not newline then
      return
    end
    local line = parser.pending:sub(1, newline - 1):gsub("\r$", "")
    parser.pending = parser.pending:sub(newline + 1)
    local data = line:match("^data:%s?(.*)$")
    if data and data ~= "[DONE]" then
      local ok, decoded = pcall(vim.json.decode, data)
      if ok then
        local choice = decoded.choices and decoded.choices[1]
        if choice and choice.finish_reason then
          parser.finish_reason = choice.finish_reason
        end
        local content = choice and choice.delta and choice.delta.content
        -- llama.cpp names it reasoning_content, mlx-lm names it reasoning.
        local reasoning = choice
          and choice.delta
          and (choice.delta.reasoning_content or choice.delta.reasoning)
        append_tool_calls(parser, choice and choice.delta and choice.delta.tool_calls)
        if type(content) == "string" and content ~= "" then
          parser.content = parser.content .. content
          vim.schedule(function()
            parser.on_chunk(content)
          end)
        end
        if type(reasoning) == "string" and reasoning ~= "" then
          parser.reasoning = parser.reasoning .. reasoning
          if parser.on_reasoning then
            vim.schedule(function()
              parser.on_reasoning(reasoning)
            end)
          end
        end
      end
    end
  end
end

function M.start(url, payload, callbacks)
  local parser = {
    pending = "",
    content = "",
    reasoning = "",
    tool_calls = {},
    on_chunk = callbacks.on_chunk,
    on_reasoning = callbacks.on_reasoning,
  }
  local stderr = {}
  local process = vim.system({
    "curl",
    "--silent",
    "--show-error",
    "--no-buffer",
    "--fail-with-body",
    "-H",
    "Content-Type: application/json",
    "--data-binary",
    "@-",
    url .. "/v1/chat/completions",
  }, {
    stdin = vim.json.encode(payload),
    text = true,
    stdout = function(_, data)
      feed_sse(parser, data)
    end,
    stderr = function(_, data)
      if data then
        stderr[#stderr + 1] = data
      end
    end,
  }, function(result)
    vim.schedule(function()
      if result.code == 0 then
        callbacks.on_done({
          finish_reason = parser.finish_reason,
          content = parser.content,
          reasoning_content = parser.reasoning,
          tool_calls = completed_tool_calls(parser),
        })
      elseif result.signal ~= 15 then
        callbacks.on_error(vim.trim(table.concat(stderr)) ~= "" and vim.trim(table.concat(stderr)) or "Request failed")
      end
    end)
  end)
  return function()
    process:kill(15)
  end
end

return M

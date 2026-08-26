local M = {}

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
        local reasoning = choice and choice.delta and choice.delta.reasoning_content
        if type(content) == "string" and content ~= "" then
          vim.schedule(function()
            parser.on_chunk(content)
          end)
        end
        if type(reasoning) == "string" and reasoning ~= "" and parser.on_reasoning then
          vim.schedule(function()
            parser.on_reasoning(reasoning)
          end)
        end
      end
    end
  end
end

function M.start(url, payload, callbacks)
  local parser = { pending = "", on_chunk = callbacks.on_chunk, on_reasoning = callbacks.on_reasoning }
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
        callbacks.on_done(parser.finish_reason)
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

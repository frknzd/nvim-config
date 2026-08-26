local M = {}

local state = {
  process = nil,
  owned = false,
  port = nil,
  starting = false,
  waiters = {},
  log = {},
  idle_timer = nil,
}

local function cancel_idle_timer()
  if state.idle_timer then
    state.idle_timer:stop()
    state.idle_timer:close()
    state.idle_timer = nil
  end
end

local function executable(opts)
  if opts.command then
    return vim.fn.executable(opts.command) == 1 and opts.command or nil
  end
  for _, command in ipairs({ "llama", "llama-server" }) do
    if vim.fn.executable(command) == 1 then
      return command
    end
  end
end

local function free_port()
  local socket = vim.uv.new_tcp()
  if not socket then
    return nil, "Failed to create a TCP socket"
  end
  local ok, bind_err = socket:bind("127.0.0.1", 0)
  if not ok then
    socket:close()
    return nil, "Failed to reserve a local port: " .. (bind_err or "unknown error")
  end
  local address, address_err = socket:getsockname()
  socket:close()
  if not address then
    return nil, "Failed to inspect the local port: " .. (address_err or "unknown error")
  end
  return address.port
end

local function health(url, callback)
  vim.system({ "curl", "--silent", "--fail", "--max-time", "1", url .. "/health" }, { text = true }, function(result)
    vim.schedule(function()
      callback(result.code == 0)
    end)
  end)
end

local function notify_waiters(url, err)
  local waiters = state.waiters
  state.waiters = {}
  state.starting = false
  for _, waiter in ipairs(waiters) do
    waiter(url, err)
  end
end

local function append_log(data, on_status)
  if not data or data == "" then
    return
  end
  data = data:gsub("\27%[[%d;?]*[ -/]*[@-~]", ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local status = "Starting llama.cpp"
  for _, line in ipairs(vim.split(data, "\n", { trimempty = true })) do
    line = vim.trim(line)
    if line ~= "" then
      state.log[#state.log + 1] = line
      if #state.log > 80 then
        table.remove(state.log, 1)
      end
      local progress = line:match("(%d+%%)")
      if progress then
        status = "Downloading model " .. progress
      elseif line:lower():match("load.+model") then
        status = "Loading model"
      end
    end
  end
  local snapshot = vim.deepcopy(state.log)
  vim.schedule(function()
    on_status(status, snapshot)
  end)
end

local function download_size(model)
  local repo = model:match("^([^:]+)")
  if not repo then
    return nil
  end
  local hf_home = vim.env.HF_HOME or vim.fn.expand("~/.cache/huggingface")
  local model_dir = "models--" .. repo:gsub("/", "--")
  local pattern = vim.fs.joinpath(hf_home, "hub", model_dir, "blobs", "*.downloadInProgress")
  local total = 0
  for _, filename in ipairs(vim.fn.glob(pattern, false, true)) do
    local stat = vim.uv.fs_stat(filename)
    total = total + (stat and stat.size or 0)
  end
  return total > 0 and total or nil
end

local function report_download(opts, on_status)
  local bytes = download_size(opts.model)
  if not bytes then
    return
  end
  local downloaded_gb = bytes / 1000000000
  local status
  if opts.model_size_gb then
    local percent = math.min(99, math.floor(downloaded_gb / opts.model_size_gb * 100))
    status = ("Downloading model · %.2f / %.2f GB (%d%%)"):format(downloaded_gb, opts.model_size_gb, percent)
  else
    status = ("Downloading model · %.2f GB received"):format(downloaded_gb)
  end
  local lines = vim.deepcopy(state.log)
  lines[#lines + 1] = status
  on_status(status, lines)
end

local function poll_ready(url, opts, on_status, started_at)
  health(url, function(ready)
    if ready then
      notify_waiters(url)
      return
    end
    if not state.process then
      local detail = state.log[#state.log] or "llama server exited before becoming ready"
      notify_waiters(nil, detail)
      return
    end
    if vim.uv.now() - started_at > opts.startup_timeout * 1000 then
      M.stop()
      notify_waiters(nil, "Timed out waiting for the model to load")
      return
    end
    report_download(opts, on_status)
    vim.defer_fn(function()
      poll_ready(url, opts, on_status, started_at)
    end, 300)
  end)
end

function M.ensure(opts, on_status, callback)
  cancel_idle_timer()
  if opts.endpoint then
    health(opts.endpoint, function(ok)
      callback(ok and opts.endpoint or nil, ok and nil or ("No healthy LLM server at %s"):format(opts.endpoint))
    end)
    return
  end

  if state.starting then
    state.waiters[#state.waiters + 1] = callback
    return
  end

  local command = executable(opts)
  if not command then
    callback(nil, "Install llama.cpp (`brew install llama.cpp`) and retry.")
    return
  end

  if not state.port then
    local port, port_err = free_port()
    if not port then
      callback(nil, port_err)
      return
    end
    state.port = port
  end
  local url = ("http://127.0.0.1:%d"):format(state.port)
  if state.process then
    health(url, function(ok)
      if ok then
        callback(url)
      else
        M.stop()
        M.ensure(opts, on_status, callback)
      end
    end)
    return
  end

  state.starting = true
  state.waiters[#state.waiters + 1] = callback
  state.log = {}

  local args = { command }
  if command:match("/llama$") or command == "llama" then
    args[#args + 1] = "serve"
  end
  vim.list_extend(args, {
    "-hf",
    opts.model,
    "--host",
    "127.0.0.1",
    "--port",
    tostring(state.port),
    "-c",
    tostring(opts.context_size),
    "--no-mmproj",
  })
  if opts.reasoning_budget ~= nil then
    vim.list_extend(args, { "--reasoning-budget", tostring(opts.reasoning_budget) })
    if opts.reasoning_budget_message then
      vim.list_extend(args, { "--reasoning-budget-message", opts.reasoning_budget_message })
    end
  end
  state.log[1] = "$ " .. table.concat(args, " ")
  on_status("Starting llama.cpp", vim.deepcopy(state.log))

  state.owned = true
  state.process = vim.system(args, {
    text = true,
    stdout = function(_, data)
      append_log(data, on_status)
    end,
    stderr = function(_, data)
      append_log(data, on_status)
    end,
  }, function(result)
    vim.schedule(function()
      state.process = nil
      state.owned = false
      if state.starting then
        local detail = state.log[#state.log] or result.stderr or ("llama server exited (%d)"):format(result.code)
        notify_waiters(nil, detail)
      end
    end)
  end)
  poll_ready(url, opts, on_status, vim.uv.now())
end

function M.idle(seconds)
  cancel_idle_timer()
  if not state.process or not state.owned or not seconds or seconds <= 0 then
    return
  end
  state.idle_timer = vim.uv.new_timer()
  state.idle_timer:start(seconds * 1000, 0, vim.schedule_wrap(function()
    cancel_idle_timer()
    M.stop()
  end))
end

function M.stop()
  cancel_idle_timer()
  if state.process and state.owned then
    state.process:kill(15)
  end
  state.process = nil
  state.owned = false
  state.starting = false
end

function M.logs()
  return vim.deepcopy(state.log)
end

function M.is_starting()
  return state.starting
end

return M

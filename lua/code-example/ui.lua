local M = {}

local icons = {
  busy = "󰔟",
  done = "󰄬",
  error = "󰅚",
  info = "󰋼",
}

local activity_words = {
  { "Rummaging", "Function" },
  { "Scrying", "Special" },
  { "Unspooling", "String" },
  { "Triangulating", "Type" },
  { "Percolating", "Identifier" },
  { "Ferreting", "DiagnosticInfo" },
  { "Gloaming", "Number" },
}

---@class CodeExampleView
---@field buf integer
---@field win integer
---@field thinking_buf integer
---@field thinking_win integer
---@field content string
---@field thinking_content string
---@field status_message string
---@field status_index integer
---@field status_timer uv.uv_timer_t?
---@field on_retry fun()?
---@field on_cancel fun()?

local View = {}
View.__index = View

local function dimensions()
  local available_width = math.max(30, vim.o.columns - 4)
  local available_height = math.max(10, vim.o.lines - 6)
  local width = math.min(140, available_width, math.max(50, math.floor(vim.o.columns * 0.88)))
  local height = math.min(48, available_height, math.max(14, math.floor(vim.o.lines * 0.8)))
  return width, height
end

function View:is_valid()
  return vim.api.nvim_buf_is_valid(self.buf)
    and vim.api.nvim_win_is_valid(self.win)
    and vim.api.nvim_buf_is_valid(self.thinking_buf)
    and vim.api.nvim_win_is_valid(self.thinking_win)
end

function View:set_thinking(content)
  if not self:is_valid() then
    return
  end
  self.thinking_content = content
  local lines = vim.split(content, "\n", { plain = true })
  vim.bo[self.thinking_buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.thinking_buf, 0, -1, false, lines)
  vim.bo[self.thinking_buf].modifiable = false
  vim.api.nvim_win_set_cursor(self.thinking_win, { math.max(1, #lines), 0 })
end

function View:append_thinking(content)
  if type(content) ~= "string" or content == "" or not self:is_valid() then
    return
  end
  local combined = self.thinking_content .. content
  if #combined > 4000 then
    combined = "…" .. combined:sub(-3999)
  end
  self:set_thinking(combined)
end

function View:render_status(message, kind)
  if not self:is_valid() then
    return
  end
  local icon = icons[kind] or icons.info
  local hl = kind == "error" and "DiagnosticError" or kind == "done" and "DiagnosticOk" or "DiagnosticInfo"
  local footer
  if kind == "busy" then
    local activity = activity_words[self.status_index]
    footer = {
      { (" %s "):format(activity[1]), activity[2] },
      { ("· %s "):format(message), "Comment" },
    }
  else
    footer = { { (" %s %s "):format(icon, message), hl } }
  end
  vim.api.nvim_win_set_config(self.win, {
    footer = footer,
    footer_pos = "left",
  })
end

function View:stop_status_animation()
  if self.status_timer then
    self.status_timer:stop()
    self.status_timer:close()
    self.status_timer = nil
  end
end

function View:status(message, kind)
  if not self:is_valid() then
    return
  end
  self.status_message = message
  if kind ~= "busy" then
    self:stop_status_animation()
    self:render_status(message, kind)
    return
  end
  self.status_index = self.status_index or 1
  self:render_status(message, kind)
  if self.status_timer then
    return
  end
  self.status_timer = vim.uv.new_timer()
  self.status_timer:start(500, 500, vim.schedule_wrap(function()
    if not self:is_valid() then
      self:stop_status_animation()
      return
    end
    self.status_index = self.status_index % #activity_words + 1
    self:render_status(self.status_message, "busy")
  end))
end

function View:set_content(content)
  if not self:is_valid() then
    return
  end
  self.content = content
  local lines = vim.split(content, "\n", { plain = true })
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
end

function View:append(content)
  if content == "" or not self:is_valid() then
    return
  end
  self:set_content(self.content .. content)
end

function View:close()
  self:stop_status_animation()
  if self.on_cancel then
    self.on_cancel()
  end
  if vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  if vim.api.nvim_win_is_valid(self.thinking_win) then
    vim.api.nvim_win_close(self.thinking_win, true)
  end
end

function M.open(title)
  local width, height = dimensions()
  local buf = vim.api.nvim_create_buf(false, true)
  local thinking_buf = vim.api.nvim_create_buf(false, true)
  local thinking_height = math.floor((height - 2) / 2)
  local response_height = height - thinking_height - 2
  local row = math.max(0, math.floor((vim.o.lines - height - 2) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = response_height,
    style = "minimal",
    border = "rounded",
    title = (" %s "):format(title),
    title_pos = "center",
  })
  local thinking_win = vim.api.nvim_open_win(thinking_buf, false, {
    relative = "editor",
    row = row + response_height + 2,
    col = col,
    width = width,
    height = thinking_height,
    style = "minimal",
    border = "rounded",
    title = " Model Insight ",
    title_pos = "center",
  })

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.wo[win].conceallevel = 2
  vim.wo[win].linebreak = true
  vim.wo[win].wrap = true
  vim.wo[win].cursorline = false
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"

  vim.bo[thinking_buf].buftype = "nofile"
  vim.bo[thinking_buf].bufhidden = "wipe"
  vim.bo[thinking_buf].swapfile = false
  vim.bo[thinking_buf].filetype = "markdown"
  vim.bo[thinking_buf].modifiable = false
  vim.wo[thinking_win].linebreak = true
  vim.wo[thinking_win].wrap = true
  vim.wo[thinking_win].cursorline = false
  vim.wo[thinking_win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"

  local view = setmetatable({
    buf = buf,
    win = win,
    thinking_buf = thinking_buf,
    thinking_win = thinking_win,
    content = "",
    thinking_content = "",
    status_message = "",
    status_index = 1,
    status_timer = nil,
  }, View)
  for _, target_buf in ipairs({ buf, thinking_buf }) do
    vim.keymap.set("n", "q", function()
      view:close()
    end, { buffer = target_buf, nowait = true, desc = "Close code example" })
    vim.keymap.set("n", "<Esc>", function()
      view:close()
    end, { buffer = target_buf, nowait = true, desc = "Close code example" })
    vim.keymap.set("n", "r", function()
      if view.on_retry then
        view.on_retry()
      end
    end, { buffer = target_buf, nowait = true, desc = "Regenerate code example" })
  end

  view:set_content("Preparing context…\n\nPress `q` to close or `r` to regenerate.")
  view:set_thinking("Waiting for LSP context…")
  view:status("Inspecting LSP context", "busy")
  return view
end

return M

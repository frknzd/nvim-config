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

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local shortcuts_ns = vim.api.nvim_create_namespace("code_example_shortcuts")
local tools_ns = vim.api.nvim_create_namespace("code_example_tools")
local shortcuts_items = {
  { key = "q", label = "close" },
  { key = "r", label = "resend" },
  { key = "s", label = "stop" },
}

local function render_shortcuts(bufnr, win)
  local parts = {}
  for _, item in ipairs(shortcuts_items) do
    parts[#parts + 1] = item.key .. " " .. item.label
  end
  local text = table.concat(parts, "    ")
  local width = vim.api.nvim_win_get_width(win)
  local pad = math.max(0, math.floor((width - vim.fn.strdisplaywidth(text)) / 2))
  local line = string.rep(" ", pad) .. text
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
  vim.bo[bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(bufnr, shortcuts_ns, 0, -1)
  local pos = pad
  for _, item in ipairs(shortcuts_items) do
    vim.api.nvim_buf_add_highlight(bufnr, shortcuts_ns, "Title", 0, pos, pos + #item.key)
    pos = pos + #item.key + 1 + #item.label + 4
  end
end

local function render_tools(bufnr, win, recent_tool, count)
  local count_text = ("%d %s called"):format(count, count == 1 and "tool" or "tools")
  local left = recent_tool and ("Tool Used: %s"):format(recent_tool) or ""
  local width = vim.api.nvim_win_get_width(win)
  local available_left = math.max(0, width - vim.fn.strdisplaywidth(count_text) - 3)
  if vim.fn.strdisplaywidth(left) > available_left then
    left = vim.fn.strcharpart(left, 0, math.max(0, available_left - 1)) .. "…"
  end
  local padding = string.rep(" ", math.max(1, width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(count_text)))
  local line = left .. padding .. count_text
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
  vim.bo[bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(bufnr, tools_ns, 0, -1)
  if left ~= "" then
    vim.api.nvim_buf_add_highlight(bufnr, tools_ns, "Function", 0, 0, #left)
  end
  local count_start = #left + #padding
  vim.api.nvim_buf_add_highlight(bufnr, tools_ns, "Comment", 0, count_start, count_start + #count_text)
end

---@class CodeExampleView
---@field buf integer
---@field win integer
---@field thinking_buf integer
---@field thinking_win integer
---@field tools_buf integer
---@field tools_win integer
---@field shortcuts_buf integer
---@field shortcuts_win integer
---@field content string
---@field thinking_content string
---@field status_message string
---@field status_kind string
---@field status_index integer
---@field spinner_index integer
---@field status_timer uv.uv_timer_t?
---@field tool_count integer
---@field recent_tool string?
---@field recent_tool_timer uv.uv_timer_t?
---@field markdown_rendered boolean
---@field auto_resize boolean
---@field response_height integer
---@field thinking_height integer
---@field default_response_height integer
---@field default_thinking_height integer
---@field inner_height integer
---@field row integer
---@field col integer
---@field width integer
---@field applied_row integer?
---@field applied_col integer?
---@field applied_width integer?
---@field resize_autocmd integer?
---@field on_retry fun()?
---@field on_cancel fun()?
---@field on_stop fun()?

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
    and vim.api.nvim_buf_is_valid(self.tools_buf)
    and vim.api.nvim_win_is_valid(self.tools_win)
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
  local footer_pos = "center"
  if kind == "busy" then
    local activity = activity_words[math.max(1, self.status_index)]
    local spinner = spinner_frames[self.spinner_index]
    footer = {
      { (" %s "):format(spinner), "DiagnosticInfo" },
      { ("%s "):format(activity[1]), activity[2] },
    }
  else
    footer = { { (" %s %s "):format(icon, message), hl } }
  end
  vim.api.nvim_win_set_config(self.thinking_win, {
    footer = footer,
    footer_pos = footer_pos,
  })
end

function View:stop_status_spinner()
  if self.status_timer then
    self.status_timer:stop()
    self.status_timer:close()
    self.status_timer = nil
  end
end

function View:status(message, kind, cycle)
  if not self:is_valid() then
    return
  end
  self.status_message = message
  self.status_kind = kind
  if kind == "busy" and cycle then
    self.status_index = self.status_index % #activity_words + 1
  end
  self:render_status(message, kind)
  if kind ~= "busy" then
    self:stop_status_spinner()
    return
  end
  if self.status_timer then
    return
  end
  self.status_timer = vim.uv.new_timer()
  self.status_timer:start(80, 80, vim.schedule_wrap(function()
    if not self:is_valid() then
      self:stop_status_spinner()
      return
    end
    self.spinner_index = self.spinner_index % #spinner_frames + 1
    self:render_status(self.status_message, "busy")
  end))
end

function View:tool_used(name, arguments)
  if not self:is_valid() then
    return
  end
  self.tool_count = self.tool_count + 1
  local args = type(arguments) == "string" and arguments:gsub("%s+", " ") or "{}"
  self.recent_tool = ("%s %s"):format(name or "unknown", args)
  render_tools(self.tools_buf, self.tools_win, self.recent_tool, self.tool_count)
  if self.recent_tool_timer then
    self.recent_tool_timer:stop()
    self.recent_tool_timer:close()
  end
  self:render_status(self.status_message, "busy")
  self.recent_tool_timer = vim.uv.new_timer()
  self.recent_tool_timer:start(1000, 0, vim.schedule_wrap(function()
    if self.recent_tool_timer then
      self.recent_tool_timer:stop()
      self.recent_tool_timer:close()
      self.recent_tool_timer = nil
    end
    self.recent_tool = nil
    if self:is_valid() then
      render_tools(self.tools_buf, self.tools_win, nil, self.tool_count)
      self:render_status(self.status_message, self.status_kind)
    end
  end))
end

function View:reset_tools()
  self.tool_count = 0
  self.recent_tool = nil
  if self.recent_tool_timer then
    self.recent_tool_timer:stop()
    self.recent_tool_timer:close()
    self.recent_tool_timer = nil
  end
  if self:is_valid() then
    render_tools(self.tools_buf, self.tools_win, nil, 0)
  end
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
  self:resize_for_content()
end

function View:set_markdown_rendering(enabled)
  if not self:is_valid() or self.markdown_rendered == enabled then
    return
  end
  local ok, renderer = pcall(require, "render-markdown")
  if not ok then
    return
  end
  vim.api.nvim_buf_call(self.buf, function()
    if enabled then
      renderer.buf_enable()
    else
      renderer.buf_disable()
    end
  end)
  self.markdown_rendered = enabled
end

function View:resize(response_height, thinking_height)
  if not self:is_valid() then
    return
  end
  local unchanged = self.response_height == response_height
    and self.thinking_height == thinking_height
    and self.applied_row == self.row
    and self.applied_col == self.col
    and self.applied_width == self.width
  if unchanged then
    return
  end
  self.response_height = response_height
  self.thinking_height = thinking_height
  self.applied_row = self.row
  self.applied_col = self.col
  self.applied_width = self.width
  vim.api.nvim_win_set_config(self.win, {
    relative = "editor",
    row = self.row,
    col = self.col,
    width = self.width,
    height = response_height,
  })
  vim.api.nvim_win_set_config(self.thinking_win, {
    relative = "editor",
    row = self.row + response_height + 2,
    col = self.col,
    width = self.width,
    height = thinking_height,
  })
  vim.api.nvim_win_set_config(self.tools_win, {
    relative = "editor",
    row = self.row + response_height + 2 + thinking_height + 2,
    col = self.col,
    width = self.width,
    height = 1,
  })
  vim.api.nvim_win_set_config(self.shortcuts_win, {
    relative = "editor",
    row = self.row + response_height + 2 + thinking_height + 5,
    col = self.col,
    width = self.width,
    height = 1,
  })
  render_tools(self.tools_buf, self.tools_win, self.recent_tool, self.tool_count)
  render_shortcuts(self.shortcuts_buf, self.shortcuts_win)
end

function View:reflow()
  if not self:is_valid() then
    return
  end
  local width, height = dimensions()
  self.width = width
  self.row = math.max(0, math.floor((vim.o.lines - height - 2) / 2) - 1)
  self.col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local thinking_height = math.floor((height - 2) / 2)
  local response_height = height - thinking_height - 2
  thinking_height = math.max(1, thinking_height - 6)
  self.default_response_height = response_height
  self.default_thinking_height = thinking_height
  self.inner_height = response_height + thinking_height
  if self.auto_resize then
    self:resize_for_content()
  else
    self:resize(response_height, thinking_height)
  end
end

function View:resize_for_content()
  if not self.auto_resize or not self:is_valid() then
    return
  end
  local ok, measured = pcall(vim.api.nvim_win_text_height, self.win, { start_row = 0, end_row = -1 })
  local required = ok and measured.all or vim.api.nvim_buf_line_count(self.buf)
  local max_response_height = self.inner_height - 1
  local response_height = math.min(max_response_height, math.max(self.default_response_height, required + 1))
  self:resize(response_height, self.inner_height - response_height)
  if required + 1 > max_response_height then
    vim.api.nvim_win_set_cursor(self.win, { vim.api.nvim_buf_line_count(self.buf), 0 })
  end
end

function View:set_auto_resize(enabled)
  self.auto_resize = enabled
  if enabled then
    self:resize_for_content()
  else
    self:resize(self.default_response_height, self.default_thinking_height)
  end
end

function View:append(content)
  if content == "" or not self:is_valid() then
    return
  end
  self:set_content(self.content .. content)
end

function View:close()
  self:stop_status_spinner()
  if self.recent_tool_timer then
    self.recent_tool_timer:stop()
    self.recent_tool_timer:close()
    self.recent_tool_timer = nil
  end
  if self.resize_autocmd then
    pcall(vim.api.nvim_del_autocmd, self.resize_autocmd)
    self.resize_autocmd = nil
  end
  if self.on_cancel then
    self.on_cancel()
  end
  if vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  if vim.api.nvim_win_is_valid(self.thinking_win) then
    vim.api.nvim_win_close(self.thinking_win, true)
  end
  if vim.api.nvim_win_is_valid(self.tools_win) then
    vim.api.nvim_win_close(self.tools_win, true)
  end
  if vim.api.nvim_win_is_valid(self.shortcuts_win) then
    vim.api.nvim_win_close(self.shortcuts_win, true)
  end
end

function M.open(title)
  local width, height = dimensions()
  local buf = vim.api.nvim_create_buf(false, true)
  local thinking_buf = vim.api.nvim_create_buf(false, true)
  local tools_buf = vim.api.nvim_create_buf(false, true)
  local shortcuts_buf = vim.api.nvim_create_buf(false, true)
  local thinking_height = math.floor((height - 2) / 2)
  local response_height = height - thinking_height - 2
  thinking_height = math.max(1, thinking_height - 6)
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
  local shortcuts_win = vim.api.nvim_open_win(shortcuts_buf, false, {
    relative = "editor",
    row = row + response_height + 2 + thinking_height + 5,
    col = col,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
  })
  local tools_win = vim.api.nvim_open_win(tools_buf, false, {
    relative = "editor",
    row = row + response_height + 2 + thinking_height + 2,
    col = col,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
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

  vim.bo[tools_buf].buftype = "nofile"
  vim.bo[tools_buf].bufhidden = "wipe"
  vim.bo[tools_buf].swapfile = false
  vim.bo[tools_buf].modifiable = false
  vim.wo[tools_win].cursorline = false
  vim.wo[tools_win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
  render_tools(tools_buf, tools_win, nil, 0)

  vim.bo[shortcuts_buf].buftype = "nofile"
  vim.bo[shortcuts_buf].bufhidden = "wipe"
  vim.bo[shortcuts_buf].swapfile = false
  vim.bo[shortcuts_buf].modifiable = false
  vim.wo[shortcuts_win].cursorline = false
  vim.wo[shortcuts_win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
  render_shortcuts(shortcuts_buf, shortcuts_win)

  local view = setmetatable({
    buf = buf,
    win = win,
    thinking_buf = thinking_buf,
    thinking_win = thinking_win,
    tools_buf = tools_buf,
    tools_win = tools_win,
    shortcuts_buf = shortcuts_buf,
    shortcuts_win = shortcuts_win,
    content = "",
    thinking_content = "",
    status_message = "",
    status_kind = "info",
    status_index = 1,
    spinner_index = 1,
    status_timer = nil,
    tool_count = 0,
    recent_tool = nil,
    recent_tool_timer = nil,
    markdown_rendered = false,
    auto_resize = false,
    response_height = response_height,
    thinking_height = thinking_height,
    default_response_height = response_height,
    default_thinking_height = thinking_height,
    inner_height = response_height + thinking_height,
    row = row,
    col = col,
    width = width,
    applied_row = row,
    applied_col = col,
    applied_width = width,
  }, View)
  view.resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
    callback = function()
      view:reflow()
    end,
  })
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
    vim.keymap.set("n", "s", function()
      if view.on_stop then
        view.on_stop()
      end
    end, { buffer = target_buf, nowait = true, desc = "Stop the current model response" })
  end

  view:set_content("Preparing context…\n\nPress `q` to close or `r` to regenerate.")
  view:set_thinking("Waiting for LSP context…")
  view:status("Inspecting LSP context", "busy")
  return view
end

return M

local M = {}

local namespace = vim.api.nvim_create_namespace("code-example-status")

local icons = {
  busy = "󰔟",
  done = "󰄬",
  error = "󰅚",
  info = "󰋼",
}

---@class CodeExampleView
---@field buf integer
---@field win integer
---@field status_mark integer
---@field content string
---@field on_retry fun()?
---@field on_cancel fun()?

local View = {}
View.__index = View

local function dimensions()
  local width = math.min(100, math.max(50, math.floor(vim.o.columns * 0.72)))
  local height = math.min(34, math.max(12, math.floor(vim.o.lines * 0.68)))
  return width, height
end

function View:is_valid()
  return vim.api.nvim_buf_is_valid(self.buf) and vim.api.nvim_win_is_valid(self.win)
end

function View:status(message, kind)
  if not self:is_valid() then
    return
  end
  local icon = icons[kind] or icons.info
  local hl = kind == "error" and "DiagnosticError" or kind == "done" and "DiagnosticOk" or "DiagnosticInfo"
  self.status_mark = vim.api.nvim_buf_set_extmark(self.buf, namespace, 0, 0, {
    id = self.status_mark,
    virt_text = { { (" %s %s "):format(icon, message), hl } },
    virt_text_pos = "right_align",
    priority = 200,
  })
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
  if self.on_cancel then
    self.on_cancel()
  end
  if vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
end

function M.open(title)
  local width, height = dimensions()
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = (" %s "):format(title),
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

  local view = setmetatable({ buf = buf, win = win, content = "", status_mark = nil }, View)
  vim.keymap.set("n", "q", function()
    view:close()
  end, { buffer = buf, nowait = true, desc = "Close code example" })
  vim.keymap.set("n", "<Esc>", function()
    view:close()
  end, { buffer = buf, nowait = true, desc = "Close code example" })
  vim.keymap.set("n", "r", function()
    if view.on_retry then
      view.on_retry()
    end
  end, { buffer = buf, nowait = true, desc = "Regenerate code example" })

  view:set_content("Preparing context…\n\nPress `q` to close or `r` to regenerate.")
  view:status("Inspecting LSP context", "busy")
  return view
end

return M

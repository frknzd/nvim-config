local function is_editor_window(win)
  return win ~= 0
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_config(win).relative == ""
end

local function find_editor_window()
  local current = vim.api.nvim_get_current_win()
  if is_editor_window(current) then
    return current
  end

  local alternate_number = vim.fn.winnr("#")
  if alternate_number > 0 then
    local alternate = vim.fn.win_getid(alternate_number)
    if is_editor_window(alternate) then
      return alternate
    end
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_editor_window(win) then
      return win
    end
  end
end

local function open_hover_link(uri)
  if not vim.startswith(uri, "file://") then
    return require("noice.util").open(uri)
  end

  local file_uri, fragment = uri:match("^([^#]+)#?(.*)$")
  local ok, path = pcall(vim.uri_to_fname, file_uri)
  if not ok or not path then
    vim.notify("Invalid file URI: " .. uri, vim.log.levels.ERROR)
    return
  end

  local stat = (vim.uv or vim.loop).fs_stat(path)
  if not stat or stat.type ~= "file" then
    vim.notify("Hover link does not point to a file: " .. path, vim.log.levels.ERROR)
    return
  end

  local win = find_editor_window()
  if not win then
    vim.notify("No editor window available for hover link", vim.log.levels.ERROR)
    return
  end

  vim.api.nvim_set_current_win(win)
  local opened, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
  if not opened then
    vim.notify("Failed to open hover link:\n" .. err, vim.log.levels.ERROR)
    return
  end

  local line = tonumber(fragment:match("[Ll](%d+)"))
  if line then
    line = math.max(1, math.min(line, vim.api.nvim_buf_line_count(0)))

    local column = tonumber(fragment:match("[Cc](%d+)")) or 1
    local text = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ""
    column = math.max(0, math.min(column - 1, #text))

    vim.api.nvim_win_set_cursor(0, { line, column })
    vim.cmd("normal! zz")
  end
end

local function cursor_is_in_function_arguments()
  local ok, node = pcall(vim.treesitter.get_node, { ignore_injections = false })
  if not ok then
    return false
  end

  while node do
    local node_type = node:type()
    if
      node_type:find("argument", 1, true)
      and not node_type:find("type_argument", 1, true)
      and not node_type:find("generic_argument", 1, true)
      and not node_type:find("template_argument", 1, true)
    then
      return true
    end
    node = node:parent()
  end

  return false
end

local signature_inactive_namespace = vim.api.nvim_create_namespace("blink_signature_inactive")

local function dim_inactive_signature_help(signature_window)
  local buffer = signature_window.win:get_buf()
  if not vim.api.nvim_buf_is_valid(buffer) then
    return
  end

  vim.api.nvim_buf_clear_namespace(buffer, signature_inactive_namespace, 0, -1)

  local blink_namespace = require("blink.cmp.config").appearance.highlight_ns
  local active_mark
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buffer, blink_namespace, 0, -1, { details = true })) do
    if
      mark[4].hl_group == "BlinkCmpSignatureHelpActiveParameter"
      and (not active_mark or mark[1] > active_mark[1])
    then
      active_mark = mark
    end
  end
  if not active_mark then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  local last_signature_line = #lines - 1
  for line, text in ipairs(lines) do
    if text == "" then
      last_signature_line = line - 2
      break
    end
  end

  local active_start_line = active_mark[2]
  local active_start_column = active_mark[3]
  local active_end_line = active_mark[4].end_row or active_start_line
  local active_end_column = active_mark[4].end_col or active_start_column

  local function dim(line, start_column, end_column)
    if start_column >= end_column then
      return
    end
    vim.api.nvim_buf_set_extmark(buffer, signature_inactive_namespace, line, start_column, {
      end_col = end_column,
      hl_group = "BlinkCmpSignatureHelpInactive",
      priority = 4097,
    })
  end

  for line = 0, last_signature_line do
    local line_length = #(lines[line + 1] or "")
    if line < active_start_line or line > active_end_line then
      dim(line, 0, line_length)
    elseif line == active_start_line then
      dim(line, 0, active_start_column)
    end
    if line == active_end_line then
      dim(line, active_end_column, line_length)
    end
  end
end

local function preserve_active_signature_highlights()
  local signature_window = require("blink.cmp.signature.window")
  if signature_window.inactive_highlights_installed then
    return
  end

  -- Blink enables wrapping here but, unlike its completion documentation
  -- window, does not enable word-aware line breaks. The same window contains
  -- both the signature and its documentation, so this keeps either section
  -- from wrapping in the middle of a type or prose word.
  signature_window.win.config.linebreak = true

  local open_with_signature_help = signature_window.open_with_signature_help
  signature_window.open_with_signature_help = function(...)
    local result = open_with_signature_help(...)
    dim_inactive_signature_help(signature_window)
    return result
  end
  signature_window.inactive_highlights_installed = true
end

return {
  -- Noice only keeps the popup open while the last char is `(`, so it vanishes
  -- as soon as you type an argument. Let blink.cmp own signature help instead.
  {
    "folke/noice.nvim",
    opts = {
      lsp = {
        signature = {
          enabled = false,
        },
      },
      markdown = {
        hover = {
          ["%[.-%]%((%S-)%)"] = open_hover_link,
        },
      },
      views = {
        hover = {
          border = {
            style = "rounded",
            padding = { 0, 1 },
          },
          position = { row = 2, col = 1 },
          size = {
            width = "auto",
            height = "auto",
            max_width = 64,
            max_height = 16,
          },
          win_options = {
            winhighlight = {
              Normal = "NoiceHover",
              FloatBorder = "NoiceHoverBorder",
            },
            wrap = true,
            linebreak = true,
          },
        },
      },
    },
  },

  -- Stays open after `(`, follows the cursor, highlights the active arg.
  -- Servers that retrigger on `,` advance the highlight to the next parameter.
  {
    "saghen/blink.cmp",
    init = function()
      vim.api.nvim_create_autocmd("User", {
        pattern = "LazyLoad",
        callback = function(event)
          if event.data == "blink.cmp" then
            preserve_active_signature_highlights()
            return true
          end
        end,
      })
    end,
    opts = {
      keymap = {
        -- One context-sensitive popup toggle: signature help inside function
        -- arguments, completion everywhere else.
        ["<C-space>"] = {
          function(cmp)
            if cmp.is_visible() or cmp.is_signature_visible() then
              cmp.hide()
              cmp.hide_signature()
              return true
            end

            if cursor_is_in_function_arguments() then
              return cmp.show_signature()
            end
            return cmp.show()
          end,
        },
        ["<C-e>"] = false,
        ["<C-k>"] = false,
      },
      completion = {
        menu = {
          -- A compact, adaptive menu is easier to scan than a full-width strip.
          min_width = 34,
          max_height = 12,
          border = "rounded",
          scrolloff = 1,
          scrollbar = false,
          direction_priority = { "s", "n" },
          draw = {
            -- Keep the popup anchored to the beginning of the completion word.
            align_to = "label",
            padding = { 1, 1 },
            gap = 1,
            treesitter = { "lsp" },
            columns = {
              { "kind_icon" },
              { "label", "label_description", gap = 1 },
              { "kind" },
            },
            components = {
              label = {
                text = function(ctx)
                  return ctx.label .. ctx.label_detail
                end,
                highlight = function(ctx)
                  local highlights = {
                    {
                      0,
                      #ctx.label,
                      group = ctx.deprecated and "BlinkCmpLabelDeprecated" or "BlinkCmpLabel",
                    },
                  }

                  if ctx.label_detail then
                    table.insert(highlights, {
                      #ctx.label,
                      #ctx.label + #ctx.label_detail,
                      group = "BlinkCmpLabelDetail",
                    })
                  end

                  if vim.list_contains(ctx.self.treesitter, ctx.source_id) and not ctx.deprecated then
                    vim.list_extend(
                      highlights,
                      require("blink.cmp.completion.windows.render.treesitter").highlight(ctx)
                    )
                  end

                  for _, index in ipairs(ctx.label_matched_indices) do
                    table.insert(highlights, {
                      index,
                      index + 1,
                      group = "BlinkCmpLabelMatch",
                    })
                  end

                  return highlights
                end,
              },
              label_description = {
                text = function(ctx)
                  return ctx.label_description
                end,
                highlight = "BlinkCmpLabelDescription",
              },
              kind = {
                ellipsis = false,
                text = function(ctx)
                  return ctx.kind
                end,
                highlight = function(ctx)
                  return ctx.kind_hl
                end,
              },
            },
          },
        },
        documentation = {
          auto_show = true,
          auto_show_delay_ms = 250,
          update_delay_ms = 50,
          window = {
            min_width = 30,
            max_width = 64,
            max_height = 16,
            border = "rounded",
            scrollbar = false,
          },
        },
        -- LazyVim turns this on via `vim.g.ai_cmp`; no inline preview while typing.
        ghost_text = { enabled = false },
      },
      signature = {
        enabled = true,
        trigger = {
          show_on_trigger_character = true,
          show_on_insert_on_trigger_character = true,
          show_on_accept = true,
        },
        window = {
          show_documentation = true,
          -- Keep each token's usual syntax color in the active parameter.
          treesitter_highlighting = true,
          border = "rounded",
          scrollbar = false,
        },
      },
    },
  },
}

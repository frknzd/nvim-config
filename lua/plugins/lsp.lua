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

return {
  -- zls inserts `print(comptime fmt: []const u8, args: anytype)` as snippet
  -- placeholders when this is on. Turn it off so accept inserts `print()`.
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        zls = {
          settings = {
            zls = {
              enable_snippets = true,
              enable_argument_placeholders = false,
              -- Keep Zig buffers free of inline parameter and type hints.
              inlay_hints_show_parameter_name = false,
              inlay_hints_show_variable_type_hints = false,
              inlay_hints_show_struct_literal_field_type = false,
              inlay_hints_show_builtin = false,
            },
          },
        },
      },
    },
  },

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
  -- zls retriggers on `,` so the highlight advances to the next parameter.
  {
    "saghen/blink.cmp",
    opts = {
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
          show_documentation = false,
          min_width = 30,
          max_width = 72,
          max_height = 8,
          border = "rounded",
          scrollbar = false,
        },
      },
    },
  },
}

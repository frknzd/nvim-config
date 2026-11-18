-- Use the full width and leave a thin strip below the floating views.
local picker_size = { width = 0, height = 0.99, min_width = 0, min_height = 0 }

local function fit_picker_list(picker)
  local list = picker.list
  local pending, last_layout, last_width

  local function resize()
    pending = false
    if picker.closed or not list.win:valid() then
      return
    end

    local layout = picker.layout
    local root = layout.opts.layout
    local left, preview = root[1], root[2]
    -- Leave stacked layouts, sidebars and pickers without a right preview alone.
    if root.box ~= "horizontal" or root.width ~= 0 or root.relative == "win" or #root ~= 2
      or left.box ~= "vertical" or preview.win ~= "preview" or not layout:needs_layout("preview")
    then
      return
    end

    local frame = layout.box_wins[left.id]
    local border = frame and frame:border_size() or { left = 0, right = 0 }
    local root_border = layout.root:border_size()
    local function limit()
      local columns = vim.o.columns - root_border.left - root_border.right
      return math.max(1, math.floor(columns / 2) - border.left - border.right)
    end

    local cap = limit()
    local width = math.min(24, cap) -- Keep the search prompt usable for short or empty results.
    for _, item in ipairs(list.visible) do
      -- Resolve paths at the maximum width, not at the current (possibly truncated) width.
      local chunks = Snacks.picker.highlight.resolve(picker.format(item, picker), cap)
      local parts = {}
      for _, chunk in ipairs(chunks) do
        if type(chunk[1]) == "string" then
          parts[#parts + 1] = chunk[1]
        end
      end
      local cells = vim.fn.strdisplaywidth(table.concat(parts):gsub("%s+$", ""))
      width = math.min(cap, math.max(width, cells + 2)) -- Selection marker and padding.
      if width == cap then
        break
      end
    end

    if layout ~= last_layout or width ~= last_width then
      last_layout, last_width = layout, width
      left.width = function()
        -- Give the results all the space when the preview is toggled off.
        return layout:needs_layout("preview") and math.min(width, limit()) or 0
      end
      preview.width = 0 -- The preview gets all remaining columns.
      layout:update()
    end
  end

  local function schedule_resize()
    if not pending then
      pending = true
      vim.schedule(resize)
    end
  end

  -- A list can change without the selected item (and preview) changing.
  vim.api.nvim_buf_attach(list.win.buf, false, { on_lines = schedule_resize })
  schedule_resize()
end

return {
  {
    "folke/snacks.nvim",
    opts = {
      -- snacks writes ~/.cache/nvim/lazygit-theme.yml by resolving these
      -- highlight groups; the LazyGit* ones are defined in
      -- lua/plugins/colorschemes.lua. The defaults reuse editor groups, which
      -- with monokai gives a white cherry-pick background and a washed-out
      -- inactive border.
      lazygit = {
        win = { width = 0, height = 0.99 },
        -- stylua: ignore
        theme = {
          [241]                      = { fg = "LazyGitGrey" },
          activeBorderColor          = { fg = "LazyGitActiveBorder", bold = true },
          inactiveBorderColor        = { fg = "LazyGitInactiveBorder" },
          searchingActiveBorderColor = { fg = "LazyGitSearchingBorder", bold = true },
          -- lazygit wants plain color values here, and snacks deep-merges with
          -- its defaults, so both must use the `fg` key or the default
          -- `fg = "Identifier"` leaks in as a second (white) color.
          cherryPickedCommitBgColor  = { fg = "LazyGitCherryPickedBg" },
          cherryPickedCommitFgColor  = { fg = "LazyGitCherryPickedFg" },
          defaultFgColor             = { fg = "LazyGitDefaultFg" },
          optionsTextColor           = { fg = "LazyGitOptionsText" },
          selectedLineBgColor        = { bg = "LazyGitSelectedLine" },
          unstagedChangesColor       = { fg = "LazyGitUnstagedChanges" },
        },
      },
      picker = {
        config = function(opts)
          local on_show = opts.on_show
          opts.on_show = function(picker)
            if on_show then
              on_show(picker)
            end
            if picker.list.win:valid() then
              fit_picker_list(picker)
            end
          end
        end,
        layouts = {
          default = { layout = picker_size },
          vertical = { layout = picker_size },
        },
        sources = {
          explorer = {
            actions = {
              --- Expand package-style directory chains in one step.
              ---@param picker snacks.Picker
              ---@param item snacks.picker.explorer.Item
              ---@param action snacks.picker.Action
              explorer_open_single_child = function(picker, item, action)
                local actions = require("snacks.explorer.actions")

                -- Keep the normal behavior for files, searches, and closing an
                -- already-open directory.
                if not item or not item.dir or item.open or picker.input.filter.meta.searching then
                  return actions.actions.confirm(picker, item, action)
                end

                local tree = require("snacks.explorer.tree")
                local node = tree:find(item.file)
                local visible = tree:filter(picker.opts)

                while node and node.dir do
                  node.open = true
                  tree:expand(node)

                  local children = {}
                  for _, child in pairs(node.children) do
                    if visible(child) then
                      children[#children + 1] = child
                    end
                  end

                  -- Only skip an unambiguous, real-directory child. Avoid
                  -- following directory symlinks, which may contain cycles.
                  if #children ~= 1 or children[1].type ~= "directory" then
                    break
                  end
                  node = children[1]
                end

                actions.update(picker, { target = node.path, refresh = true })
              end,
            },
            win = {
              list = {
                keys = {
                  ["l"] = "explorer_open_single_child",
                },
              },
            },
          },
        },
      },
    },
  },
}

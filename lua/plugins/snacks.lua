return {
  {
    "folke/snacks.nvim",
    opts = {
      picker = {
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

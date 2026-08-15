return {
  {
    "folke/which-key.nvim",
    opts = {
      -- Discover multi-key prefixes in every mode, not only the normal,
      -- visual/select, and operator-pending modes enabled by default.
      triggers = {
        { "<auto>", mode = { "n", "i", "x", "s", "o", "t", "c" } },
      },
    },
    keys = {
      {
        "<leader>?",
        function()
          -- LazyVim's default uses `global = false`, which hides global
          -- mappings such as <C-Space>. Expand the whole normal-mode tree so
          -- single-key mappings and non-leader prefixes are visible as well.
          require("which-key").show({ mode = "n", expand = true })
        end,
        desc = "All Normal Keymaps (which-key)",
      },
    },
  },
}

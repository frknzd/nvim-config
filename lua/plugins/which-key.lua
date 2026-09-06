return {
  {
    "folke/which-key.nvim",
    opts = {
      -- Discover multi-key prefixes in every mode, not only the normal,
      -- visual/select, and operator-pending modes enabled by default.
      triggers = {
        { "<auto>", mode = { "n", "i", "x", "s", "o", "t", "c" } },
      },
      -- which-key resolves a pressed key against the visible node *before* it
      -- checks its scroll keys, so a scroll key that is also a mapping never
      -- scrolls. The default <c-u> is mapped in insert mode (i_CTRL-U-default),
      -- which bites here because triggers are enabled for `i` as well.
      -- <PageDown>/<PageUp> are unmapped in every mode (fn+Down / fn+Up).
      keys = {
        scroll_down = "<PageDown>",
        scroll_up = "<PageUp>",
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

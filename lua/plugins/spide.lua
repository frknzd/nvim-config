-- Spide ↔ Neovim: reveal the code under the cursor in Spide's diagram, open diagram elements
-- here (⌘-click in Spide), forward live LSP diagnostics as health evidence, review agent patches.
-- The plugin lives in the Spide repository; nothing else in this config is changed.
local dir = vim.fn.expand("~/Projects/Spide/integrations/nvim")

return {
  {
    dir = dir,
    name = "spide.nvim",
    cond = function()
      return (vim.uv or vim.loop).fs_stat(dir) ~= nil
    end,
    lazy = false,
    opts = {
      auto_connect = true, -- attach when a buffer inside a running Spide workspace opens
      follow_cursor = false, -- :SpideFollow toggles revealing the cursor's element on CursorHold
      forward_diagnostics = true,
      keymaps = "<leader>j", -- <leader>jr reveal · jh health · ja ask · jt trace · jp patches · jc connect
    },
    config = function(_, opts)
      require("spide").setup(opts)
      local ok, wk = pcall(require, "which-key")
      if ok then
        wk.add({ { "<leader>j", group = "spide" } })
      end
    end,
  },
}

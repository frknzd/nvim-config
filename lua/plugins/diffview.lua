-- diffview.nvim: tabpage-based git diff / file history viewer.
-- All mappings live under <leader>gv, which is unused by LazyVim's git keys
-- (<leader>g{b,B,c,d,D,e,f,g,G,h*,i,I,l,L,o,p,P,r,s,S,Y}).
return {
  {
    "sindrets/diffview.nvim",
    cmd = {
      "DiffviewOpen",
      "DiffviewClose",
      "DiffviewToggleFiles",
      "DiffviewFocusFiles",
      "DiffviewRefresh",
      "DiffviewFileHistory",
    },
    keys = {
      {
        "<leader>gvv",
        function()
          if next(require("diffview.lib").views) == nil then
            vim.cmd("DiffviewOpen")
          else
            vim.cmd("DiffviewClose")
          end
        end,
        desc = "Toggle Diffview",
      },
      { "<leader>gvo", "<cmd>DiffviewOpen<cr>", desc = "Open (working tree vs index)" },
      { "<leader>gvc", "<cmd>DiffviewClose<cr>", desc = "Close" },
      { "<leader>gvs", "<cmd>DiffviewOpen --staged<cr>", desc = "Staged Changes" },
      { "<leader>gvm", "<cmd>DiffviewOpen origin/HEAD...HEAD --imply-local<cr>", desc = "Branch vs Default (PR review)" },
      { "<leader>gvh", "<cmd>DiffviewFileHistory %<cr>", desc = "File History (current file)" },
      { "<leader>gvH", "<cmd>DiffviewFileHistory<cr>", desc = "Repo History" },
      { "<leader>gvh", ":DiffviewFileHistory<cr>", mode = "x", desc = "Selection History" },
      { "<leader>gvf", "<cmd>DiffviewToggleFiles<cr>", desc = "Toggle File Panel" },
      { "<leader>gvr", "<cmd>DiffviewRefresh<cr>", desc = "Refresh" },
    },
    opts = {
      enhanced_diff_hl = true,
      view = {
        merge_tool = { layout = "diff3_mixed" },
      },
      -- `q` closes diffview from any of its windows (diffview removes these
      -- buffer-local maps again when the view closes).
      keymaps = {
        view = { { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close Diffview" } } },
        file_panel = { { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close Diffview" } } },
        file_history_panel = { { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close Diffview" } } },
      },
    },
  },
  {
    "folke/which-key.nvim",
    opts = {
      spec = {
        { "<leader>gv", group = "diffview", mode = { "n", "x" } },
      },
    },
  },
}

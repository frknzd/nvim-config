-- Pairs with the tmux-side plugin already listed in ~/.tmux.conf, so <C-h/j/k/l>
-- crosses nvim splits and tmux panes with the same keys. These `keys` entries
-- take over LazyVim's default <C-w>h/j/k/l window maps.
return {
  {
    "christoomey/vim-tmux-navigator",
    cmd = {
      "TmuxNavigateLeft",
      "TmuxNavigateDown",
      "TmuxNavigateUp",
      "TmuxNavigateRight",
      "TmuxNavigatePrevious",
    },
    keys = {
      { "<C-h>", "<cmd>TmuxNavigateLeft<cr>", desc = "Go to Left Window/Pane" },
      { "<C-j>", "<cmd>TmuxNavigateDown<cr>", desc = "Go to Lower Window/Pane" },
      { "<C-k>", "<cmd>TmuxNavigateUp<cr>", desc = "Go to Upper Window/Pane" },
      { "<C-l>", "<cmd>TmuxNavigateRight<cr>", desc = "Go to Right Window/Pane" },
      { "<C-\\>", "<cmd>TmuxNavigatePrevious<cr>", desc = "Go to Previous Window/Pane" },
    },
  },
}

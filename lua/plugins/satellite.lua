-- IntelliJ-style scroll marker bar: git changes + diagnostics in the scrollbar.
return {
  {
    "lewis6991/satellite.nvim",
    event = "VeryLazy",
    opts = {
      current_only = false,
      winblend = 50,
      zindex = 40,
      excluded_filetypes = {
        "snacks_dashboard",
        "snacks_picker_list",
        "snacks_picker_input",
        "snacks_terminal",
        "trouble",
        "lazy",
        "mason",
        "help",
        "dapui_scopes",
        "dapui_breakpoints",
        "dapui_stacks",
        "dapui_watches",
        "dap-repl",
      },
      -- NOTE: the README documents a `width` option, but nothing in the plugin
      -- source ever reads it, so it is omitted here rather than kept as a
      -- config option that silently does nothing.
      handlers = {
        cursor = { enable = true },
        search = { enable = true },
        diagnostic = {
          enable = true,
          signs = { "-", "=", "≡" },
          min_severity = vim.diagnostic.severity.HINT,
        },
        gitsigns = {
          enable = true,
          signs = { add = "│", change = "│", delete = "-" },
        },
        marks = { enable = true, show_builtins = false },
        quickfix = { enable = true, signs = { "-", "=", "≡" } },
      },
    },
    -- Colors need no overrides: satellite links SatelliteGitSigns* -> GitSigns*
    -- and SatelliteDiagnostic* -> Diagnostic*, both defined by gruvbox-chroma.
    -- satellite ships only :SatelliteEnable / :SatelliteDisable / :SatelliteRefresh
    -- (no toggle command), so track the state ourselves.
    keys = {
      {
        "<leader>uS",
        function()
          vim.g.satellite_disabled = not vim.g.satellite_disabled
          vim.cmd(vim.g.satellite_disabled and "SatelliteDisable" or "SatelliteEnable")
          vim.notify("Scrollbar " .. (vim.g.satellite_disabled and "disabled" or "enabled"))
        end,
        desc = "Toggle Scrollbar (satellite)",
      },
    },
  },
}

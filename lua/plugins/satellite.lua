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
    -- Deleted lines produce a single scrollbar row (a delete hunk has
    -- `added.count == 0`), while add/change hunks usually span several rows.
    -- satellite renders one mark per row per handler -- `apply_mark` reuses the
    -- extmark id `pos + 1`, so for a given row the *last* mark wins -- and the
    -- gitsigns handler emits marks in hunk order. A deletion therefore
    -- disappears whenever a later add/change hunk maps onto the same row, which
    -- is the common case in any file large enough for rows to cover many lines.
    -- Re-order the handler's marks so deletions are applied last and survive.
    config = function(_, opts)
      local handlers = require("satellite.handlers")
      local register = handlers.register

      -- Hook registration rather than the handler table: builtin handlers are
      -- only loaded on the first render, which setup() below may trigger.
      handlers.register = function(spec)
        if spec.name == "gitsigns" then
          local update = spec.update
          spec.update = function(bufnr, winid)
            local marks, deletions = {}, {}
            for _, mark in ipairs(update(bufnr, winid)) do
              table.insert(mark.highlight == "SatelliteGitSignsDelete" and deletions or marks, mark)
            end
            vim.list_extend(marks, deletions)
            return marks
          end
        end
        return register(spec)
      end

      require("satellite").setup(opts)
    end,

    -- satellite only links SatelliteGitSigns* -> GitSigns* (and
    -- SatelliteDiagnostic* -> Diagnostic*) with `default = true`, which is too
    -- dim at `winblend = 50`; the explicit colors live in
    -- lua/plugins/colorschemes.lua so they get re-applied on every :colorscheme.
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

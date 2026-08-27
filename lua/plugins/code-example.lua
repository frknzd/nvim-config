return {
  {
    dir = vim.fn.stdpath("config"),
    name = "code-example.nvim",
    dependencies = {
      {
        "MeanderingProgrammer/render-markdown.nvim",
        dependencies = { "nvim-treesitter/nvim-treesitter" },
        opts = {
          enabled = false,
          overrides = {
            buftype = {
              nofile = {
                render_modes = true,
                padding = { highlight = "NormalFloat" },
                sign = { enabled = false },
                code = { left_pad = 0, right_pad = 0 },
              },
            },
          },
        },
      },
    },
    keys = {
      {
        "<leader>ce",
        function()
          require("code-example").show()
        end,
        mode = { "n", "x" },
        desc = "Annotated Code Example",
      },
    },
    cmd = { "CodeExample", "CodeExampleStop" },
    opts = {},
  },
}

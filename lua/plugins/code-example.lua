return {
  {
    dir = vim.fn.stdpath("config"),
    name = "code-example.nvim",
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

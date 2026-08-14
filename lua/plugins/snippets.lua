return {
  { "rafamadriz/friendly-snippets", enabled = false },
  {
    "saghen/blink.cmp",
    opts = {
      sources = {
        providers = {
          snippets = {
            opts = {
              friendly_snippets = false,
            },
          },
        },
      },
    },
  },
}

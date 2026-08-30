-- Rainbow delimiters only for languages that use paredit-style editing.
local lisp_languages = {
  "clojure",
  "fennel",
  "scheme",
  "commonlisp",
  "janet_simple",
}

return {
  {
    "HiPhish/rainbow-delimiters.nvim",
    config = function()
      local rainbow = require("rainbow-delimiters")

      -- Use the no-op strategy by default so rainbow highlighting does not
      -- change the appearance of non-Lisp buffers.
      local strategy = { [""] = rainbow.strategy.noop }
      local query = { [""] = "rainbow-delimiters" }
      for _, language in ipairs(lisp_languages) do
        strategy[language] = rainbow.strategy.global
        query[language] = "rainbow-delimiters"
      end

      require("rainbow-delimiters.setup").setup({
        whitelist = lisp_languages,
        strategy = strategy,
        query = query,
        highlight = {
          "RainbowDelimiterRed",
          "RainbowDelimiterYellow",
          "RainbowDelimiterBlue",
          "RainbowDelimiterOrange",
          "RainbowDelimiterGreen",
          "RainbowDelimiterViolet",
          "RainbowDelimiterCyan",
        },
      })

      -- The plugin may be loaded after FileType for the buffer opened on the
      -- command line, so attach that buffer explicitly as well.
      local function configure_buffer(buf)
        local language = vim.treesitter.language.get_lang(vim.bo[buf].filetype)
        if vim.tbl_contains(lisp_languages, language) then
          pcall(rainbow.enable, buf)
        else
          pcall(rainbow.disable, buf)
        end
      end

      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("rainbow_lisp_only", { clear = true }),
        callback = function(event)
          configure_buffer(event.buf)
        end,
      })

      configure_buffer(0)
    end,
  },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      for _, language in ipairs(lisp_languages) do
        if not vim.tbl_contains(opts.ensure_installed, language) then
          table.insert(opts.ensure_installed, language)
        end
      end
    end,
  },
}

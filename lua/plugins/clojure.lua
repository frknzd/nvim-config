-- Cursive-style structural editing, in vim-native bindings.
--
-- The slurp/barf/drag family keeps nvim-paredit's `>`/`<` operator pairs, and
-- everything else lives under <localleader>. All of it is buffer-local to the
-- lisp filetypes, so `(`, `)`, `W`, `E` and friends keep their usual meaning
-- everywhere else.

local filetypes = { "clojure", "fennel", "scheme", "lisp", "janet" }

return {
  {
    "julienvincent/nvim-paredit",
    opts = function()
      local api = require("nvim-paredit.api")
      local extras = require("paredit-extras")

      local function wrap_element(prefix, suffix)
        return function()
          api.wrap_element_under_cursor(prefix, suffix)
        end
      end

      local function wrap_form(prefix, suffix)
        return function()
          api.wrap_enclosing_form_under_cursor(prefix, suffix)
        end
      end

      -- Both halves of a pair are bound so it doesn't matter which bracket you
      -- reach for, the way Cursive's wrap actions don't care either.
      local pairs_by_key = {
        ["("] = { "(", ")", "()" },
        [")"] = { "(", ")", "()" },
        ["["] = { "[", "]", "[]" },
        ["]"] = { "[", "]", "[]" },
        ["{"] = { "{", "}", "{}" },
        ["}"] = { "{", "}", "{}" },
        ['"'] = { '"', '"', '""' },
        ["#"] = { "#{", "}", "#{}" },
      }

      local keys = {
        -- Slurp & barf.
        [">)"] = { api.slurp_forwards, "Slurp forwards" },
        ["<)"] = { api.barf_forwards, "Barf forwards" },
        ["<("] = { api.slurp_backwards, "Slurp backwards" },
        [">("] = { api.barf_backwards, "Barf backwards" },

        -- Move things around. `>f`/`<f` is Cursive's move form up/down.
        [">e"] = { api.drag_element_forwards, "Drag element right" },
        ["<e"] = { api.drag_element_backwards, "Drag element left" },
        [">p"] = { api.drag_pair_forwards, "Drag pair right" },
        ["<p"] = { api.drag_pair_backwards, "Drag pair left" },
        [">f"] = { api.drag_form_forwards, "Drag form right" },
        ["<f"] = { api.drag_form_backwards, "Drag form left" },

        -- Restructure.
        ["<localleader>ps"] = { api.unwrap_form_under_cursor, "Splice form" },
        ["<localleader>pr"] = { api.raise_form, "Raise form" },
        ["<localleader>pR"] = { api.raise_element, "Raise element" },
        ["<localleader>pS"] = { extras.split, "Split form" },
        ["<localleader>pJ"] = { extras.join, "Join forms" },

        -- Delete. `pk` is Cursive's "kill sexp", `pK` its "kill".
        ["<localleader>pk"] = { api.delete_form, "Kill form" },
        ["<localleader>pK"] = { extras.kill_to_end_of_form, "Kill to end of form" },
        ["<localleader>pe"] = { api.delete_element, "Kill element" },
        ["<localleader>pi"] = { api.delete_in_form, "Kill inside form" },

        -- Element motions.
        ["W"] = { api.move_to_next_element_head, "Next element head", repeatable = false, mode = { "n", "x", "o", "v" } },
        ["E"] = { api.move_to_next_element_tail, "Next element tail", repeatable = false, mode = { "n", "x", "o", "v" } },
        ["B"] = { api.move_to_prev_element_head, "Prev element head", repeatable = false, mode = { "n", "x", "o", "v" } },
        ["gE"] = { api.move_to_prev_element_tail, "Prev element tail", repeatable = false, mode = { "n", "x", "o", "v" } },
        ["("] = { api.move_to_parent_form_start, "Parent form head", repeatable = false, mode = { "n", "x", "v" } },
        [")"] = { api.move_to_parent_form_end, "Parent form tail", repeatable = false, mode = { "n", "x", "v" } },

        -- Text objects, so `daf`, `yif`, `cie` and so on are sexp-aware.
        ["af"] = { api.select_around_form, "Around form", repeatable = false, mode = { "o", "v" } },
        ["if"] = { api.select_in_form, "In form", repeatable = false, mode = { "o", "v" } },
        ["aF"] = { api.select_around_top_level_form, "Around top level form", repeatable = false, mode = { "o", "v" } },
        ["iF"] = { api.select_in_top_level_form, "In top level form", repeatable = false, mode = { "o", "v" } },
        ["ae"] = { api.select_element, "Around element", repeatable = false, mode = { "o", "v" } },
        ["ie"] = { api.select_element, "Element", repeatable = false, mode = { "o", "v" } },
      }

      for key, pair in pairs(pairs_by_key) do
        local prefix, suffix, label = pair[1], pair[2], pair[3]
        keys["<localleader>w" .. key] = { wrap_element(prefix, suffix), "Wrap element in " .. label }
        keys["<localleader>W" .. key] = { wrap_form(prefix, suffix), "Wrap form in " .. label }
      end

      return {
        use_default_keys = false,
        filetypes = filetypes,
        keys = keys,
      }
    end,
    config = function(_, opts)
      require("nvim-paredit").setup(opts)

      -- which-key resolves `cond` once at startup, so it can't scope a group to
      -- a filetype. Name the <localleader> prefixes per-buffer instead, next to
      -- where paredit installs its own buffer-local keymaps.
      local function name_groups(buf)
        local ok, wk = pcall(require, "which-key")
        if not ok then
          return
        end
        wk.add({
          buffer = buf,
          { "<localleader>p", group = "paredit", mode = { "n", "x" } },
          { "<localleader>w", group = "wrap element", mode = { "n", "x" } },
          { "<localleader>W", group = "wrap form", mode = { "n", "x" } },
        })
      end

      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("paredit_which_key", { clear = true }),
        pattern = opts.filetypes,
        callback = function(event)
          name_groups(event.buf)
        end,
      })

      -- The buffer that triggered the load has already fired FileType, which is
      -- how paredit itself handles this case.
      if vim.tbl_contains(opts.filetypes, vim.bo.filetype) then
        name_groups(0)
      end
    end,
  },
}

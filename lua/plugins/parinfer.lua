-- Structural editing for Clojure, the Cursive way.
--
-- Two complementary pieces:
--
--   nvim-paredit  (already pulled in by lazyvim.plugins.extras.lang.clojure)
--                 normal/visual-mode s-exp ops: slurp, barf, raise, drag, ...
--                 It does *nothing* in insert mode.
--
--   nvim-parinfer this file. Watches every insert-mode keystroke and rewrites
--                 the trailing brackets so the buffer can never go unbalanced.
--                 Pure Lua, no rust/cargo build step.
--
-- Cursive is technically paredit-style (brackets are load-bearing, indentation
-- follows) whereas parinfer inverts that (indentation is load-bearing, brackets
-- follow). The observable result in insert mode is the same: you cannot produce
-- an unbalanced form. `smart` mode is the closest of the three parinfer modes to
-- Cursive, since it preserves manual bracket edits instead of re-deriving
-- everything from indentation.
--
-- mini.pairs (a LazyVim default) is deliberately left ENABLED here. It does not
-- fight parinfer over `(`/`[`/`{` -- typing `(println 1` yields an identical
-- buffer with it on or off, because mini.pairs inserts a balanced pair and
-- parinfer then has nothing to correct.
--
-- More importantly, parinfer balances brackets ONLY, never string delimiters.
-- With mini.pairs off, typing `(println "hi` leaves an unterminated string and
-- parinfer misreads the rest of the form. mini.pairs supplies the closing `"`,
-- so the two together cover what neither does alone.
return {
  {
    "gpanders/nvim-parinfer",
    ft = { "clojure", "edn" },
    init = function()
      -- The plugin defaults to a wide lisp filetype list. Restrict it to Clojure
      -- only, otherwise it also hooks fennel/scheme/janet/yuck/dune buffers.
      vim.g.parinfer_filetypes = { "clojure", "edn" }

      -- "smart" keeps your explicit bracket edits and only fixes up what your
      -- indentation implies. "indent" is stricter (brackets fully derived from
      -- indentation), "paren" is the loosest (indentation derived from brackets).
      vim.g.parinfer_mode = "smart"

      -- Clojure comments are `;`, and `#_` reader-discards must not be treated
      -- as comment starts.
      vim.g.parinfer_comment_chars = { ";" }

      -- Refuse to write a buffer parinfer considers unbalanced rather than
      -- silently reshaping it.
      vim.g.parinfer_force_balance = false
    end,
  },
}

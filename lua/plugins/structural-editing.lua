-- Key-driven structural editing, not indentation-driven buffer rewriting.
-- nvim-paredit still owns normal/visual-mode slurp, barf, etc.
return {
  { "gpanders/nvim-parinfer", enabled = false },
  {
    "kovisoft/paredit",
    ft = { "clojure" }, -- Neovim also detects .cljs, .cljc and .edn as clojure.
    init = function()
      vim.g.paredit_mode = 1
      vim.g.paredit_electric_return = 0
      -- Limit activation to Clojure; don't change other Lisp buffers.
      for _, ft in ipairs({ "lisp", "scheme", "hy", "shen", "lfe", "fennel", "janet" }) do
        vim.g["paredit_disable_" .. ft] = 1
      end

      -- Use the upstream mapping hook: no overrides of normal-mode d/c/p,
      -- motions, completion's Enter/Tab, or nvim-paredit's structural commands.
      vim.g.paredit_map_func = "ClojurePareditInsertMaps"
      vim.cmd([[
        function! ClojurePareditInsertMaps() abort
          let b:minipairs_disable = v:true
          " Paredit uses Vim syntax groups to recognize strings/comments.
          setlocal syntax=clojure
          inoremap <buffer> <expr> ( PareditInsertOpening('(', ')')
          inoremap <buffer> <expr> [ PareditInsertOpening('[', ']')
          inoremap <buffer> <expr> { PareditInsertOpening('{', '}')
          inoremap <buffer> <silent> ) <C-R>=PareditInsertClosing('(', ')')<CR>
          inoremap <buffer> <silent> ] <C-R>=PareditInsertClosing('[', ']')<CR>
          inoremap <buffer> <silent> } <C-R>=PareditInsertClosing('{', '}')<CR>
          inoremap <buffer> <expr> " PareditInsertQuotes()
          inoremap <buffer> <expr> <BS> PareditBackspace(0)
          inoremap <buffer> <expr> <C-h> PareditBackspace(0)
          inoremap <buffer> <expr> <Del> PareditDel()
        endfunction
      ]])
    end,
  },
}

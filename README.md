# Neovim config

Built on [LazyVim](https://www.lazyvim.org). Most of what you see is stock LazyVim, so its
[keymaps docs](https://www.lazyvim.org/keymaps) apply. This file only covers what's **different**.

> Tip: `<leader>?` shows every normal-mode keymap, including non-leader ones.

Requires Neovim ≥ 0.11, git, a Nerd Font, and `ripgrep`/`fd` (used by LazyVim pickers).
Optional: `lazygit`, `tmux` (with `vim-tmux-navigator` on the tmux side), `clojure-lsp`.

## Layout

```
init.lua                  -> loads lua/config/lazy.lua
lazyvim.json              -> enabled LazyVim extras (see below)
lua/config/options.lua    -> option tweaks
lua/config/clojure_completion.lua -> clojure-lsp completion fixes (used by lsp.lua)
lua/plugins/*.lua         -> one file per plugin / topic
tests/structural-editing.lua -> headless test for the paredit setup
```

## LazyVim extras enabled

DAP core, plus language support for **Clojure, Haskell, Java, JSON, Markdown, Python, Tailwind,
TOML, TypeScript (vtsls)**. Toggle with `:LazyExtras`.

## General changes

| What | Where | Notes |
| --- | --- | --- |
| No format-on-save | `options.lua` | `vim.g.autoformat = false`. Format manually with `<leader>cf`. |
| `backupcopy=yes` | `options.lua` | Writes in place so `tail -f`/file watchers see changes. |
| Monokai Pro (classic) theme | `colorschemes.lua` | Big override block so floats, pickers, completion, git signs, lazygit, etc. share one consistent dark palette. Change colors in the `palette` table at the top. |
| Flash on `s` | `flash.lua` | `s` + label to jump anywhere. |
| tmux navigation | `tmux.lua` | `<C-h/j/k/l>` moves across nvim splits **and** tmux panes. |
| Scrollbar with markers | `satellite.lua` | IntelliJ-style bar showing git changes, diagnostics, search hits, marks. Toggle `<leader>uS`. |
| Diffview | `diffview.lua` | Git diff/history UI under `<leader>gv` (see below). |
| Explorer: collapse single dirs | `snacks.lua` | In the file explorer, `l` on a folder expands chains like `src/main/java/com/foo` in one go. |
| which-key everywhere | `which-key.lua` | Hints also in insert/terminal/cmdline modes. Scroll the popup with `<PageUp>/<PageDown>`. |
| No friendly-snippets | `snippets.lua` | Only your own / LSP snippets show in completion. |

### Diffview keys (`<leader>gv…`)

| Key | Action |
| --- | --- |
| `vv` | Toggle diffview |
| `vo` / `vc` | Open / close |
| `vs` | Staged changes |
| `vm` | Current branch vs `origin/HEAD` (PR review) |
| `vh` | History of current file (or selection in visual mode) |
| `vH` | Repo history |
| `vf` / `vr` | Toggle file panel / refresh |

`q` closes diffview from any of its windows.

## Completion & LSP (`lsp.lua`)

- **blink.cmp** handles completion *and* signature help (Noice's signature popup is disabled
  because it disappears as soon as you type).
- `<C-Space>`: one toggle — shows signature help inside function arguments, completion elsewhere.
  `<C-e>` and `<C-k>` are unmapped in blink.
- Compact, bordered menu with docs auto-shown after 250 ms; no ghost text.
- Signature help dims inactive parameters so the current one stands out.
- Links in LSP hover docs (`file://…#L12`) open in a normal editor window at that line.
- Extra servers: `jsonls`, `zls` (Zig, semantic tokens on).

## Clojure

Most custom work lives here.

- **clojure-lsp root detection**: in a monorepo, uses the *outermost* `.lsp/config.edn` inside the
  git repo, so there's one server for the whole repo instead of one per module.
- **Completion fixes** (`config/clojure_completion.lua`): removes duplicates, hides CLJS-only
  symbols in `.clj` files, shows the namespace next to each item, and after 3+ chars suggests
  public vars from **not-yet-required namespaces** — accepting one adds the `:require` for you.
- Semantic tokens from clojure-lsp are disabled (treesitter does highlighting).
- **Conjure, two REPLs at once**: `.clj`/`.cljc`/`.edn` buffers talk to the JVM nREPL
  (`.nrepl-port`), `.cljs` buffers talk to shadow-cljs (`.shadow-cljs/nrepl.port`). Switching
  buffers switches REPL automatically. Conjure will **not** auto-start a babashka REPL — start
  your own REPL first.
- **Structural editing**: parinfer is **off**. Classic `paredit` handles insert mode only
  (auto-closing/balanced `()[]{}""`, protected backspace/delete). `nvim-paredit` (from the
  LazyVim Clojure extra) still provides slurp/barf etc. in normal mode.
  Test: `nvim --headless --clean -l tests/structural-editing.lua`.

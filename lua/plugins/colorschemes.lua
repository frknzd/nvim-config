-- Monokai Pro (loctvl842/monokai-pro.nvim) is the most widely used, actively
-- maintained Monokai port for Neovim: real treesitter/LSP/semantic-token
-- support and highlights for the whole LazyVim plugin set.
--
-- The `classic` filter is the original dark Monokai palette, i.e. the same one
-- ~/.config/kitty/themes/themes/Monokai.conf uses, so the editor and the
-- terminal behind it stay in sync without hand-patching the palette.
local palette = {
  green = "#a6e22e",
  orange = "#fd971f",
  red = "#f92672",
  yellow = "#e6db74",
  cyan = "#66d9ef",
  purple = "#ae81ff",
  grey = "#75715e",
  fg = "#fdfff1",
  fg_dim = "#919288",
  -- buffers use the palette's `dark1` (see `override_palette` below); the
  -- picker/explorer sits one step above it so the panel is still readable as a
  -- separate surface. Completion popups share that same panel background.
  editor = "#1d1e19",
  panel = "#24251f",
  sel = "#3e3f38",
  guide = "#5a5b52",
  bg_add = "#233120",
  bg_change = "#2f2c1c",
  bg_delete = "#3a1e22",
  bg_text = "#4a4423",
}

-- Git / diff / scrollbar colours. Re-applied on every :colorscheme so they
-- survive theme reloads (LazyVim reloads the scheme on startup).
local function apply_overrides()
  local p = palette
  local hl = function(group, val)
    vim.api.nvim_set_hl(0, group, val)
  end

  -- gitsigns: sign column
  hl("SignAdd", { fg = p.green })
  hl("SignChange", { fg = p.orange })
  hl("SignDelete", { fg = p.red })
  hl("GitSignsAdd", { fg = p.green })
  hl("GitSignsChange", { fg = p.orange })
  hl("GitSignsDelete", { fg = p.red })
  hl("GitSignsTopdelete", { fg = p.red })
  hl("GitSignsChangedelete", { fg = p.orange })
  hl("GitSignsUntracked", { fg = p.grey })
  -- gitsigns: inline word-diff in previews / blame
  hl("GitSignsAddInline", { bg = p.bg_add, fg = p.green })
  hl("GitSignsChangeInline", { bg = p.bg_text, fg = p.yellow })
  hl("GitSignsDeleteInline", { bg = p.bg_delete, fg = p.red })
  hl("GitSignsCurrentLineBlame", { fg = p.grey, italic = true })

  -- diff view (:Gitsigns preview_hunk, :diffthis, diffview.nvim, ...)
  hl("DiffAdd", { bg = p.bg_add })
  hl("DiffChange", { bg = p.bg_change })
  hl("DiffDelete", { bg = p.bg_delete, fg = p.red })
  hl("DiffText", { bg = p.bg_text, fg = p.yellow, bold = true })
  hl("diffAdded", { fg = p.green })
  hl("diffChanged", { fg = p.orange })
  hl("diffRemoved", { fg = p.red })

  -- Snacks' fancy diff preview (<leader>gD and other git pickers).
  -- Keep context neutral and preserve syntax colors on added/removed lines.
  hl("SnacksDiffAdd", { bg = "#304127" })
  hl("SnacksDiffDelete", { bg = "#49252f" })
  hl("SnacksDiffContext", { bg = p.panel })
  hl("SnacksDiffAddLineNr", { fg = p.green, bg = "#263520" })
  hl("SnacksDiffDeleteLineNr", { fg = p.red, bg = "#382027" })
  hl("SnacksDiffContextLineNr", { fg = p.fg_dim, bg = p.editor })
  hl("SnacksDiffHeader", { fg = p.cyan, bg = "#303838", bold = true })
  hl("SnacksHunkHeader", { fg = p.fg_dim, bg = p.editor })

  -- LazyVim/lualine/dashboard/snacks git counters
  hl("Added", { fg = p.green })
  hl("Changed", { fg = p.orange })
  hl("Removed", { fg = p.red })

  -- satellite.nvim scrollbar. Only foregrounds are set: the handlers draw thin
  -- glyphs (`│`, `-`, ...), so giving them a background would fill the whole
  -- scrollbar cell and make every marker a fat block.
  hl("SatelliteBar", { bg = "#49483e" })
  hl("SatelliteGitSignsAdd", { fg = p.green })
  hl("SatelliteGitSignsChange", { fg = p.orange })
  hl("SatelliteGitSignsDelete", { fg = p.red })
  hl("SatelliteCursor", { fg = p.fg })
  hl("SatelliteSearch", { fg = p.yellow })
  hl("SatelliteSearchCurrent", { fg = p.purple })
  hl("SatelliteMark", { fg = p.cyan })
  hl("SatelliteQuickfix", { fg = p.cyan })

  -- snacks picker / explorer.
  -- monokai-pro only paints the *borders*, title, prompt and tree guides with
  -- the sidebar background (#1d1e19) while the windows themselves fall back to
  -- NormalFloat (#3b3c35), so the explorer ends up as a light panel wrapped in
  -- a dark frame with dark stripes over the tree guides. Paint every picker
  -- window with the same panel background instead.
  for _, win in ipairs({ "", "List", "Input", "Preview" }) do
    hl("SnacksPicker" .. win, { fg = p.fg, bg = p.panel })
    hl("SnacksPicker" .. win .. "Border", { fg = p.guide, bg = p.panel })
    hl("SnacksPicker" .. win .. "Title", { fg = p.yellow, bg = p.panel, bold = true })
    hl("SnacksPicker" .. win .. "Footer", { fg = p.guide, bg = p.panel })
  end
  hl("SnacksPickerPreviewCursorLine", { bg = p.sel })
  hl("SnacksPickerListCursorLine", { bg = p.sel })
  hl("SnacksPickerCursorLine", { bg = p.sel })
  hl("SnacksPickerTree", { fg = p.guide, bg = p.panel })
  hl("SnacksPickerPrompt", { fg = p.cyan, bg = p.panel })
  hl("SnacksPickerMatch", { fg = p.orange, bold = true })
  hl("SnacksPickerDir", { fg = p.grey })
  hl("SnacksPickerPathHidden", { fg = p.grey })
  hl("SnacksPickerPathIgnored", { fg = p.grey })
  hl("SnacksPickerDirectory", { fg = p.cyan })
  -- git status column in the explorer
  hl("SnacksPickerGitStatusAdded", { fg = p.green })
  hl("SnacksPickerGitStatusStaged", { fg = p.green })
  hl("SnacksPickerGitStatusModified", { fg = p.orange })
  hl("SnacksPickerGitStatusDeleted", { fg = p.red })
  hl("SnacksPickerGitStatusRenamed", { fg = p.purple })
  hl("SnacksPickerGitStatusUntracked", { fg = p.grey })
  hl("SnacksPickerGitStatusIgnored", { fg = p.grey })
  hl("SnacksPickerGitStatusUnmerged", { fg = p.red })

  -- snacks dashboard + indent guides (monokai-pro's snacks module is disabled
  -- below, so these are defined here instead)
  hl("SnacksDashboardHeader", { fg = p.yellow })
  hl("SnacksDashboardIcon", { fg = p.cyan })
  hl("SnacksDashboardDesc", { fg = p.fg_dim })
  hl("SnacksDashboardKey", { fg = p.orange })
  hl("SnacksDashboardFooter", { fg = p.green })
  hl("SnacksDashboardSpecial", { fg = p.purple, bold = true })
  hl("SnacksIndent", { fg = "#3b3c35", nocombine = true })
  hl("SnacksIndentScope", { fg = p.guide, nocombine = true })

  -- Completion: one dark surface for the menu, docs and signature help.
  -- Keep label backgrounds unset so selection spans the entire row without
  -- hiding the theme's per-kind icon colours or signature syntax highlights.
  for _, win in ipairs({ "Menu", "Doc", "SignatureHelp" }) do
    hl("BlinkCmp" .. win, { fg = p.fg, bg = p.panel })
    hl("BlinkCmp" .. win .. "Border", { fg = p.guide, bg = p.panel })
  end
  hl("BlinkCmpMenuSelection", { bg = p.sel })
  hl("BlinkCmpLabel", { fg = p.fg })
  hl("BlinkCmpLabelMatch", { fg = p.orange, bold = true })
  hl("BlinkCmpLabelDetail", { fg = p.fg_dim })
  hl("BlinkCmpLabelDescription", { fg = p.fg_dim })
  hl("BlinkCmpLabelDeprecated", { fg = p.grey, strikethrough = true })
  hl("BlinkCmpSource", { fg = p.fg_dim })
  hl("BlinkCmpDocSeparator", { fg = p.guide, bg = p.panel })
  hl("BlinkCmpDocCursorLine", { bg = p.sel })
  hl("BlinkCmpScrollBarThumb", { bg = p.guide })
  hl("BlinkCmpScrollBarGutter", { bg = p.panel })

  -- Shared surfaces. Use links so lazily loaded UIs inherit the same treatment
  -- without replacing their syntax, diagnostic colours or active controls.
  hl("NormalFloat", { fg = p.fg, bg = p.panel })
  hl("FloatBorder", { fg = p.guide, bg = p.panel })
  hl("FloatTitle", { fg = p.yellow, bg = p.panel, bold = true })
  hl("FloatFooter", { fg = p.fg_dim, bg = p.panel })
  hl("WinSeparator", { fg = p.guide, bg = p.editor })
  hl("Pmenu", { fg = p.fg, bg = p.panel })
  hl("PmenuSel", { bg = p.sel })
  hl("PmenuKind", { fg = p.cyan, bg = p.panel })
  hl("PmenuExtra", { fg = p.fg_dim, bg = p.panel })
  hl("PmenuKindSel", { fg = p.cyan, bg = p.sel })
  hl("PmenuExtraSel", { fg = p.fg_dim, bg = p.sel })
  hl("PmenuSbar", { bg = p.panel })
  hl("PmenuThumb", { bg = p.guide })
  for target, groups in pairs({
    NormalFloat = {
      "LazyNormal", "MasonNormal", "WhichKeyNormal", "NoiceCmdlinePopup",
      "NoicePopup", "NoiceConfirm", "NoiceSplit", "NoiceMini",
      "NoicePopupmenu", "SnacksNormal", "SnacksNormalNC", "SnacksInputNormal",
      "SnacksNotifierHistory", "SnacksNotifierMinimal", "NotifyBackground",
    },
    FloatBorder = {
      "LazyBorder", "MasonBorder", "WhichKeyBorder", "NoiceCmdlinePopupBorder",
      "NoicePopupBorder", "NoiceConfirmBorder", "NoiceSplitBorder",
      "NoicePopupmenuBorder", "SnacksInputBorder",
    },
    FloatTitle = { "WhichKeyTitle", "NoiceCmdlinePopupTitle", "SnacksTitle", "SnacksInputTitle" },
    FloatFooter = { "SnacksFooter" },
    PmenuSel = { "NoicePopupmenuSelected" },
  }) do
    for _, group in ipairs(groups) do
      hl(group, { link = target })
    end
  end
  hl("NoiceCmdlinePopupBorderSearch", { fg = p.cyan, bg = p.panel })
  hl("LazyProp", { fg = p.green, bg = p.panel })
  hl("LazyProgressDone", { fg = p.green, bg = p.panel })
  hl("LazyProgressTodo", { fg = p.guide, bg = p.panel })
  hl("LazyButton", { fg = p.fg_dim, bg = p.panel })
  hl("LazyButtonActive", { fg = p.fg, bg = p.sel, bold = true })
  for level, colour in pairs({ ERROR = p.red, WARN = p.orange, INFO = p.cyan, DEBUG = p.fg_dim, TRACE = p.purple }) do
    hl("Notify" .. level .. "Body", { link = "NormalFloat" })
    hl("Notify" .. level .. "Border", { link = "FloatBorder" })
    hl("Notify" .. level .. "Title", { fg = colour, bg = p.panel, bold = true })
    hl("Notify" .. level .. "Icon", { fg = colour, bg = p.panel })
    local suffix = level:sub(1, 1) .. level:sub(2):lower()
    hl("SnacksNotifier" .. suffix, { link = "NormalFloat" })
    hl("SnacksNotifierBorder" .. suffix, { link = "FloatBorder" })
    hl("SnacksNotifierTitle" .. suffix, { fg = colour, bg = p.panel, bold = true })
    hl("SnacksNotifierIcon" .. suffix, { fg = colour, bg = p.panel })
  end

  -- lazygit: snacks generates ~/.cache/nvim/lazygit-theme.yml from highlight
  -- groups, so give it dedicated ones instead of borrowing editor groups
  -- (`Identifier` as a *background* made the cherry-picked rows near-white).
  hl("LazyGitGrey", { fg = p.grey })
  hl("LazyGitDefaultFg", { fg = p.fg })
  hl("LazyGitActiveBorder", { fg = p.green })
  hl("LazyGitInactiveBorder", { fg = p.guide })
  hl("LazyGitSearchingBorder", { fg = p.yellow })
  hl("LazyGitOptionsText", { fg = p.cyan })
  hl("LazyGitSelectedLine", { bg = p.sel })
  hl("LazyGitUnstagedChanges", { fg = p.red })
  -- snacks reads the *fg* of these two groups and hands the value to lazygit,
  -- which uses it as the cherry-pick fg/bg pair
  hl("LazyGitCherryPickedFg", { fg = p.editor })
  hl("LazyGitCherryPickedBg", { fg = p.purple })
end

return {
  {
    "loctvl842/monokai-pro.nvim",
    lazy = false,
    priority = 1000,
    opts = {
      transparent_background = false,
      terminal_colors = true,
      -- Keep buffers dark; panels and floats sit one shade above them.
      -- Overriding the *palette* (not the scheme) means every derived shade -
      -- CursorLine, Visual, folds, diff backgrounds - is recomputed from it.
      override_palette = function()
        return { background = "#1d1e19" }
      end,
      devicons = true,
      -- classic | pro | machine | octagon | ristretto | spectrum.
      -- NOTE: `colors/monokai-pro-<filter>.lua` calls `set_filter()` itself, so
      -- the filter is really selected by the colorscheme name below; this only
      -- sets the default for a bare `:colorscheme monokai-pro`.
      filter = "classic",
      inc_search = "background",
      background_clear = { "float_win", "toggleterm", "telescope", "notify" },
      -- These two are painted in `apply_overrides()` above. monokai-pro applies
      -- its own versions lazily (when `snacks`/`gitsigns` are first required),
      -- i.e. *after* the ColorScheme autocmd, so it would otherwise clobber the
      -- git sign colors and re-introduce the mismatched picker backgrounds.
      disabled_plugins = { "folke/snacks.nvim", "lewis6991/gitsigns.nvim" },
      plugins = {
        bufferline = { underline_selected = false },
        indent_blankline = { context_highlight = "default", context_start_underline = false },
      },
    },
    config = function(_, opts)
      require("monokai-pro").setup(opts)

      local group = vim.api.nvim_create_augroup("monokai_pro_overrides", { clear = true })
      vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = apply_overrides })

      -- monokai-pro hooks `package.searchers` and paints a plugin's highlights
      -- the first time its module is required - long after `ColorScheme` fired.
      -- lazy.nvim emits `User LazyLoad` right after that, so re-run the
      -- overrides there; otherwise which-key, noice, lazy, mason, ... each
      -- restore their own float background and break the shared one.
      local pending = false
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "LazyLoad",
        callback = function()
          if pending then
            return
          end
          pending = true
          vim.schedule(function()
            pending = false
            if vim.g.colors_name and vim.g.colors_name:match("monokai") then
              apply_overrides()
            end
          end)
        end,
      })

      if vim.g.colors_name and vim.g.colors_name:match("monokai") then
        apply_overrides()
      end
    end,
  },

  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "monokai-pro-classic",
    },
  },
}

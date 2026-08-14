-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Write in place instead of rename+create. Otherwise a floating terminal
-- (tail -f, zig watch, cat of an already-open fd) keeps the old inode.
vim.opt.backupcopy = "yes"

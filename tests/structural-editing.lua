-- Run from the config directory: nvim --headless --clean -l tests/structural-editing.lua
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/paredit')
vim.cmd('syntax on')
local spec = dofile('lua/plugins/structural-editing.lua')
spec[2].init()
vim.cmd('runtime plugin/paredit.vim')
local cases = {
  {'insert nested', '', 0, 'i([{}', '([{}])'},
  {'skip closers', '', 0, 'i([])', '([])'},
  {'empty pair BS', '', 0, 'i(<BS>', ''},
  {'protect opener BS', '(abc)', 1, 'i<BS>', '(abc)'},
  {'protect closer BS', '(abc)', 4, 'a<BS>', '(abc)'},
  {'protect closer Del', '(abc)', 4, 'i<Del>', '(abc)'},
  {'delete ordinary', '(abc)', 3, 'i<BS>', '(ac)'},
  {'string literal', '"abc"', 2, 'i(', '"a(bc"'},
  {'comment literal', '; abc', 3, 'i(', '; a(bc'},
  {'empty pair Del', '()', 1, 'i<Del>', ''},
}
vim.o.backspace = 'indent,eol,start'
for _, c in ipairs(cases) do
  vim.cmd('enew!')
  vim.bo.filetype = 'clojure'
  vim.api.nvim_buf_set_lines(0,0,-1,false,{c[2]})
  vim.api.nvim_win_set_cursor(0,{1,c[3]})
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(c[4]..'<Esc>',true,false,true),'xt',false)
  local actual=table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false),'\n')
  assert(actual==c[5], c[1]..': '..vim.inspect(actual)..' expected '..vim.inspect(c[5]))
  print('PASS '..c[1])
end
vim.cmd('qa!')

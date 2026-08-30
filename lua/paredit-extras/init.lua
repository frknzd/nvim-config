-- Structural editing operations that nvim-paredit does not ship: sexp split,
-- sexp join and Cursive's "kill to end of form".
--
-- These are built on nvim-paredit's own treesitter helpers so that they agree
-- with the rest of the plugin about what counts as a form, an element and a
-- comment.

local ts_forms = require("nvim-paredit.treesitter.forms")
local ts_utils = require("nvim-paredit.treesitter.utils")
local traversal = require("nvim-paredit.utils.traversal")

local M = {}

-- Strings are not forms as far as paredit's queries are concerned, but split,
-- join and kill all treat them as one.
local string_nodes = {
  str_lit = true,
  regex_lit = true,
  string = true,
}

local function cursor()
  local pos = vim.api.nvim_win_get_cursor(0)
  return { pos[1] - 1, pos[2] }
end

local function lt(a, b)
  if a[1] ~= b[1] then
    return a[1] < b[1]
  end
  return a[2] < b[2]
end

local function lte(a, b)
  return not lt(b, a)
end

local function starts(node)
  local row, col = node:start()
  return { row, col }
end

local function ends(node)
  local row, col = node:end_()
  return { row, col }
end

local function form_opts(context)
  return { captures = context.captures, use_source = false }
end

-- nvim-paredit scopes its capture index to the top-level form under the cursor,
-- which is all its own operations ever need. Join reaches across two top-level
-- forms, so index the whole document instead.
local function create_context()
  local node = vim.treesitter.get_node()
  if not node then
    return nil
  end

  local lang = vim.treesitter.language.get_lang(vim.bo.filetype)
  if not lang then
    return nil
  end

  local query = vim.treesitter.query.get(lang, "paredit/forms")
  if not query then
    return nil
  end

  local captures = {}
  local buf = vim.api.nvim_get_current_buf()
  for id, captured in query:iter_captures(node:tree():root(), buf) do
    local key = captured:id()
    captures[key] = captures[key] or {}
    table.insert(captures[key], query.captures[id])
  end

  return { node = node, captures = captures }
end

-- The delimiters of `node`, or nil if it has none. `open.to` is the position
-- just after the opening delimiter and `close.from` the position just before
-- the closing one, which is where split and join need to write.
local function delimiters(node, context)
  if string_nodes[node:type()] then
    local start_row, start_col = node:start()
    local end_row, end_col = node:end_()
    return {
      open = { text = '"', to = { start_row, start_col + 1 } },
      close = { text = '"', from = { end_row, end_col - 1 } },
    }
  end

  if not ts_forms.node_is_form(node, { captures = context.captures }) then
    return nil
  end

  local edges = ts_forms.get_form_edges(node, context)
  return {
    open = { text = edges.left.text, to = { edges.left.range[3], edges.left.range[4] } },
    close = { text = edges.right.text, from = { edges.right.range[1], edges.right.range[2] } },
  }
end

-- Split the form under the cursor in two: `(a b| c d)` becomes `(a b) (c d)`.
-- Inside a string it splits the string instead.
function M.split()
  local context = create_context()
  if not context then
    return
  end

  local pos = cursor()
  local node = context.node

  if string_nodes[node:type()] then
    local start_row, start_col = node:start()
    local end_row, end_col = node:end_()
    -- Only between the quotes, never on them.
    if lte({ start_row, start_col + 1 }, pos) and lt(pos, { end_row, end_col - 1 }) then
      vim.api.nvim_buf_set_text(0, pos[1], pos[2], pos[1], pos[2], { '" "' })
      vim.api.nvim_win_set_cursor(0, { pos[1] + 1, pos[2] })
      return
    end
  end

  local form = ts_forms.find_nearest_form(node, form_opts(context))
  if not form or ts_utils.is_document_root(form) then
    return
  end

  -- A cursor resting on a form's own brackets is really positioned between that
  -- form and its siblings, so split the level above it.
  while not ts_utils.is_document_root(form) do
    local bounds = delimiters(form, context)
    if not bounds or (lte(bounds.open.to, pos) and lt(pos, bounds.close.from)) then
      break
    end
    local parent = ts_forms.get_node_root(form, context):parent()
    if not parent then
      break
    end
    local outer = ts_forms.find_nearest_form(parent, form_opts(context))
    if not outer or outer:equal(form) or ts_utils.is_document_root(outer) then
      break
    end
    form = outer
  end

  local edges = delimiters(form, context)
  if not edges then
    return
  end

  local inner = ts_forms.get_form_inner(form, context)
  local children = traversal.get_children_ignoring_comments(inner, context)

  -- Everything starting before the cursor stays in the left half; the split
  -- lands on an element boundary rather than mid-symbol.
  local close_at = edges.open.to
  local open_at = edges.close.from
  for _, child in ipairs(children) do
    if lt(starts(child), pos) then
      close_at = ends(child)
    end
  end
  for _, child in ipairs(children) do
    if not lt(starts(child), pos) then
      open_at = starts(child)
      break
    end
  end

  local gap = vim.api.nvim_buf_get_text(0, close_at[1], close_at[2], open_at[1], open_at[2], {})
  if #gap == 1 and gap[1] == "" then
    -- The halves are flush against each other, so introduce the separator too.
    -- stylua: ignore
    vim.api.nvim_buf_set_text(0,
      close_at[1], close_at[2],
      open_at[1], open_at[2],
      { edges.close.text .. " " .. edges.open.text }
    )
  else
    -- Write back to front so the earlier position stays valid.
    vim.api.nvim_buf_set_text(0, open_at[1], open_at[2], open_at[1], open_at[2], { edges.open.text })
    vim.api.nvim_buf_set_text(0, close_at[1], close_at[2], close_at[1], close_at[2], { edges.close.text })
  end

  vim.api.nvim_win_set_cursor(0, { close_at[1] + 1, close_at[2] })
end

local function joinable(a, b, context)
  local left = delimiters(a, context)
  local right = delimiters(b, context)
  if not left or not right then
    return false
  end
  return left.open.text == right.open.text and left.close.text == right.close.text
end

local function join_pair(a, b, context)
  local left = delimiters(a, context)
  local right = delimiters(b, context)
  -- stylua: ignore
  vim.api.nvim_buf_set_text(0,
    left.close.from[1], left.close.from[2],
    right.open.to[1], right.open.to[2],
    { " " }
  )
  vim.api.nvim_win_set_cursor(0, { left.close.from[1] + 1, left.close.from[2] })
  return true
end

-- Join the two adjacent forms around the cursor: `(a b)| (c d)` becomes
-- `(a b c d)`. With the cursor inside a form, that form is joined with the
-- sibling before it, falling back to the one after it.
function M.join()
  local context = create_context()
  if not context then
    return
  end

  local pos = cursor()
  local form = ts_forms.find_nearest_form(context.node, form_opts(context))
  if not form then
    return
  end

  -- The cursor may already be resting in the whitespace between two children.
  -- At the top level that whitespace belongs to the document root, whose
  -- children are the top-level forms themselves.
  local inner = ts_utils.is_document_root(form) and form or ts_forms.get_form_inner(form, context)
  local before, after
  for _, child in ipairs(traversal.get_children_ignoring_comments(inner, context)) do
    if lte(ends(child), pos) then
      before = child
    end
    if not after and lte(pos, starts(child)) then
      after = child
    end
  end
  if before and after and joinable(before, after, context) then
    return join_pair(before, after, context)
  end

  -- Otherwise walk outwards until we reach a form that has a sibling to join.
  local node = form
  while node and not ts_utils.is_document_root(node) do
    local element = ts_forms.get_node_root(node, context)
    if not element then
      return
    end

    local prev = traversal.get_prev_sibling_ignoring_comments(element, context)
    if prev and joinable(prev, element, context) then
      return join_pair(prev, element, context)
    end

    local following = traversal.get_next_sibling_ignoring_comments(element, context)
    if following and joinable(element, following, context) then
      return join_pair(element, following, context)
    end

    local parent = element:parent()
    if not parent then
      return
    end
    node = ts_forms.find_nearest_form(parent, form_opts(context))
    -- find_nearest_form is inclusive, so bail out if we haven't moved up.
    if not node or node:equal(element) then
      return
    end
  end
end

-- Cut everything between `from` and `to` into the target register. `floor` is
-- the leftmost column the cursor may be pulled back to when trimming the
-- whitespace the cut leaves stranded.
local function kill_to(from, to, floor)
  if not lt(from, to) then
    return
  end

  local killed = vim.api.nvim_buf_get_text(0, from[1], from[2], to[1], to[2], {})
  vim.fn.setreg(vim.v.register, table.concat(killed, "\n"), "c")
  vim.api.nvim_buf_set_text(0, from[1], from[2], to[1], to[2], {})

  local line = vim.api.nvim_buf_get_lines(0, from[1], from[1] + 1, false)[1] or ""
  local kept = (line:sub(1, from[2]):gsub("[ \t]+$", ""))
  local col = math.max(#kept, floor)
  if col < from[2] then
    vim.api.nvim_buf_set_text(0, from[1], col, from[1], from[2], {})
  end
  vim.api.nvim_win_set_cursor(0, { from[1] + 1, col })
end

-- Cursive's "Kill": cut from the cursor to the end of the enclosing form, so
-- `(a b| c d)` becomes `(a b)`. Inside a string it stops at the closing quote.
function M.kill_to_end_of_form()
  local context = create_context()
  if not context then
    return
  end

  local from = cursor()
  local node = context.node

  if string_nodes[node:type()] then
    local start_row, start_col = node:start()
    local end_row, end_col = node:end_()
    if lte({ start_row, start_col + 1 }, from) and lt(from, { end_row, end_col - 1 }) then
      -- Whitespace is significant in a string, so never trim it.
      return kill_to(from, { end_row, end_col - 1 }, from[2])
    end
  end

  local form = ts_forms.find_nearest_form(node, form_opts(context))
  if not form or ts_utils.is_document_root(form) then
    return
  end

  local edges = delimiters(form, context)
  if not edges then
    return
  end

  local floor = edges.open.to[1] == from[1] and edges.open.to[2] or 0
  kill_to(from, edges.close.from, floor)
end

return M

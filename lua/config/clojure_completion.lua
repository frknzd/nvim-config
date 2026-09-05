-- Workarounds for clojure-lsp completion gaps. Only this client's completion
-- requests are decorated; rename/navigation remain server-owned.
local M = {}

local function unresolved(item, kind)
  for _, entry in ipairs((item.data or {}).unresolved or {}) do
    if entry[1] == kind then
      return entry[2]
    end
  end
end

function M.compatible(from, target)
  local a, b = from:match("%.(clj[sc]?)$"), target:match("%.(clj[sc]?)$")
  -- Keep CLJ macros available in CLJS; only the reverse is unambiguously invalid.
  return not (a == "clj" and b == "cljs")
end

local function file_lines(uri)
  if not uri or not vim.startswith(uri, "file://") then
    return
  end
  local name = vim.uri_to_fname(uri)
  local buf = vim.fn.bufnr(name)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  local ok, lines = pcall(vim.fn.readfile, name)
  return ok and lines or nil
end

local function namespace(lines)
  -- Be conservative for unusual metadata-bearing ns forms: don't guess.
  for _, line in ipairs(lines or {}) do
    local ns = line:match("^%s*%(ns%s+([%w_.%-]+)")
    if ns then
      return ns
    end
  end
end

function M.filter(items, uri)
  local result, seen, namespaces = {}, {}, {}
  for _, item in ipairs(items) do
    local doc, alias = unresolved(item, "documentation"), unresolved(item, "alias")
    local target = doc and doc.uri
    if not target or M.compatible(uri, target) then
      local ns = alias and alias["ns-to-add"] or (doc and doc.ns)
      if not ns and target then
        if namespaces[target] == nil then
          namespaces[target] = namespace(file_lines(target)) or false
        end
        ns = namespaces[target] or nil
      end
      if ns then
        item.labelDetails = vim.tbl_extend("force", item.labelDetails or {}, { description = ns })
        item.detail = item.detail or ns
      end
      local key = item.label .. "\0" .. (ns or target or "") .. "\0" .. tostring(item.kind)
      if not seen[key] then
        seen[key] = true
        result[#result + 1] = item
      end
    end
  end
  return result
end

function M.discovery(symbols, uri, prefix, range)
  local items, seen, files = {}, {}, {}
  for _, symbol in ipairs(symbols or {}) do
    local location = symbol.location or {}
    local target = location.uri
    if
      target
      and location.range
      and M.compatible(uri, target)
      and (symbol.kind == 12 or symbol.kind == 13 or symbol.kind == 14)
      and vim.startswith(symbol.name, prefix)
    then
      if files[target] == nil then
        files[target] = file_lines(target) or false
      end
      local lines = files[target]
      local ns = lines and namespace(lines)
      local first = location.range.start.line + 1
      local definition = lines and table.concat(vim.list_slice(lines, first, location.range["end"].line + 1), "\n")
        or ""
      -- workspace/symbol also includes private definitions. Never offer those
      -- as imports. Skip ambiguous metadata rather than inserting invalid code.
      local private = definition:find("%(defn%-") or definition:find(":private")
      local fq = ns and (ns .. "/" .. symbol.name)
      if fq and not private and not seen[fq] then
        seen[fq] = true
        items[#items + 1] = {
          label = symbol.name,
          labelDetails = { description = ns },
          detail = fq,
          kind = symbol.kind == 12 and 3 or 6,
          filterText = symbol.name,
          textEdit = { range = range, newText = fq },
          -- Use clojure-lsp's own resolver to edit the ns form safely. A fully
          -- qualified alias avoids collisions with existing short aliases.
          data = {
            unresolved = {
              { "documentation", { uri = target, ns = ns, name = symbol.name } },
              { "alias", { uri = uri, ["alias-to-add"] = ns, ["ns-to-add"] = ns } },
            },
          },
        }
      end
    end
  end
  return items
end

function M.attach(client)
  if client._clojure_completion then
    return
  end
  client._clojure_completion = true
  local request = client.request
  client.request = function(self, method, params, handler, bufnr)
    if method ~= "textDocument/completion" or not handler then
      return request(self, method, params, handler, bufnr)
    end
    local uri = params.textDocument.uri
    local buf = bufnr or vim.uri_to_bufnr(uri)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local line = vim.api.nvim_buf_get_lines(buf, params.position.line, params.position.line + 1, false)[1] or ""
    local byte = vim.str_byteindex(line, self.offset_encoding, params.position.character, false)
    local prefix = line:sub(1, byte):match('([^%s%(%[%{%)%]%},";]+)$')
    local bare = prefix and #prefix >= 3 and not prefix:find("[/:'`~@#]")
    -- Avoid discovering imports in strings/comments or ns forms. The server's
    -- native completions continue working in all of those contexts.
    local ok, node = pcall(function()
      vim.treesitter.get_parser(buf, "clojure"):parse()
      return vim.treesitter.get_node({ bufnr = buf, pos = { params.position.line, math.max(0, byte - 1) } })
    end)
    if not ok or not node then
      bare = false
    else
      while node do
        if node:type():find("str") or node:type():find("comment") then
          bare = false
        end
        if node:type() == "list_lit" then
          local text = vim.treesitter.get_node_text(node, buf)
          if text:match("^%(ns%s") then
            bare = false
          end
        end
        node = node:parent()
      end
    end
    return request(self, method, params, function(err, response, ctx, config)
      if err then
        return handler(err, response, ctx, config)
      end
      response = response and response ~= vim.NIL and response or {}
      local items = M.filter(response.items or response, uri)
      local function deliver(extra)
        if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick then
          return handler(nil, { isIncomplete = true, items = {} }, ctx, config)
        end
        vim.list_extend(items, extra or {})
        handler(nil, { isIncomplete = true, items = items }, ctx, config)
      end
      if not bare then
        return deliver()
      end
      local start = params.position.character - vim.str_utfindex(prefix, self.offset_encoding)
      local range = { start = { line = params.position.line, character = start }, ["end"] = params.position }
      local sent = request(self, "workspace/symbol", { query = prefix }, function(search_err, symbols)
        deliver(not search_err and M.discovery(symbols, uri, prefix, range) or {})
      end, buf)
      if not sent then
        deliver()
      end
    end, buf)
  end
end

return M

local M = {}

local function supports(bufnr, method)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if client:supports_method(method, bufnr) then
      return true
    end
  end
  return false
end

local function hover_text(result)
  local contents = result and result.contents
  if type(contents) == "string" then
    return contents
  end
  if type(contents) ~= "table" then
    return nil
  end
  if contents.value then
    return contents.value
  end
  local parts = {}
  for _, item in ipairs(contents) do
    parts[#parts + 1] = type(item) == "string" and item or item.value or ""
  end
  return table.concat(parts, "\n")
end

local function first_result(responses)
  for _, response in pairs(responses or {}) do
    if response.result then
      return response.result
    end
  end
end

local function definition_location(result)
  if not result then
    return nil
  end
  if result.uri or result.targetUri then
    return result
  end
  return result[1]
end

local function definition_excerpt(location, radius)
  if not location then
    return nil
  end
  local uri = location.uri or location.targetUri
  local range = location.range or location.targetSelectionRange
  if not uri or not range or not uri:match("^file:") then
    return nil
  end
  local filename = vim.uri_to_fname(uri)
  local ok, lines = pcall(vim.fn.readfile, filename)
  if not ok then
    return nil
  end
  local line = range.start.line
  local first = math.max(0, line - radius)
  local last = math.min(#lines, line + radius + 1)
  return {
    filename = filename,
    first_line = first + 1,
    text = table.concat(vim.list_slice(lines, first + 1, last), "\n"),
  }
end

local function current_excerpt(bufnr, cursor, radius)
  local first = math.max(0, cursor[1] - radius - 1)
  local last = math.min(vim.api.nvim_buf_line_count(bufnr), cursor[1] + radius)
  return first + 1, last, table.concat(vim.api.nvim_buf_get_lines(bufnr, first, last, false), "\n")
end

local severity_names = {
  [vim.diagnostic.severity.ERROR] = "Error",
  [vim.diagnostic.severity.WARN] = "Warning",
}

local function collect_diagnostics(bufnr, first_line, last_line)
  local diagnostics = vim.diagnostic.get(bufnr, { severity = { min = vim.diagnostic.severity.WARN } })
  local results = {}
  for _, diagnostic in ipairs(diagnostics) do
    local line = diagnostic.lnum + 1
    if line >= first_line and line <= last_line then
      results[#results + 1] = ("Line %d [%s]%s: %s"):format(
        line,
        severity_names[diagnostic.severity] or "Diagnostic",
        diagnostic.source and (" (%s)"):format(diagnostic.source) or "",
        vim.trim((diagnostic.message or ""):gsub("\n", " "))
      )
    end
  end
  return results
end

function M.collect(source, opts, callback)
  local bufnr = source.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    callback(nil, "The source buffer is no longer available.")
    return
  end
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    callback(nil, "Code Example requires an LSP client attached to this buffer.")
    return
  end
  if not supports(bufnr, vim.lsp.protocol.Methods.textDocument_hover) then
    callback(nil, "The attached LSP does not support textDocument/hover.")
    return
  end

  local symbol = source.symbol
  local filetype = vim.bo[bufnr].filetype
  local params = vim.lsp.util.make_position_params(source.winid, clients[1].offset_encoding)
  local pending = supports(bufnr, vim.lsp.protocol.Methods.textDocument_definition) and 2 or 1
  local hover, definition

  local function finish()
    pending = pending - 1
    if pending > 0 then
      return
    end
    local current_line, last_line, current = current_excerpt(bufnr, source.cursor, opts.context_radius)
    callback({
      symbol = symbol,
      selection = source.selection,
      filetype = filetype,
      filename = vim.api.nvim_buf_get_name(bufnr),
      current_line = current_line,
      current = current,
      hover = hover,
      definition = definition_excerpt(definition_location(definition), opts.definition_radius),
      diagnostics = collect_diagnostics(bufnr, current_line, last_line),
    })
  end

  vim.lsp.buf_request_all(bufnr, vim.lsp.protocol.Methods.textDocument_hover, params, function(responses)
    hover = hover_text(first_result(responses))
    finish()
  end)
  if pending == 2 then
    vim.lsp.buf_request_all(bufnr, vim.lsp.protocol.Methods.textDocument_definition, params, function(responses)
      definition = first_result(responses)
      finish()
    end)
  end
end

return M

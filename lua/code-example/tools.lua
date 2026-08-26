local M = {}

local methods = vim.lsp.protocol.Methods

local schemas = {
  {
    name = "lsp_hover",
    description = "Get authoritative type and documentation information for the selected symbol from the LSP.",
    parameters = { type = "object", properties = {} },
  },
  {
    name = "lsp_definition",
    description = "Find the definition of the selected symbol with the LSP. Returned files become readable.",
    parameters = { type = "object", properties = {} },
  },
  {
    name = "lsp_references",
    description = "Find usages of the selected symbol with the LSP. Useful for real examples.",
    parameters = { type = "object", properties = {} },
  },
  {
    name = "lsp_type_definition",
    description = "Find the type definition of the selected symbol with the LSP.",
    parameters = { type = "object", properties = {} },
  },
  {
    name = "lsp_implementation",
    description = "Find implementations of the selected interface or symbol with the LSP.",
    parameters = { type = "object", properties = {} },
  },
  {
    name = "lsp_workspace_symbols",
    description = "Search LSP workspace symbols by name when another related API or type must be located.",
    parameters = {
      type = "object",
      properties = { query = { type = "string", description = "Symbol name or partial name" } },
      required = { "query" },
    },
  },
  {
    name = "read_source",
    description = "Read a bounded line range from a project file or a source file previously returned by the LSP.",
    parameters = {
      type = "object",
      properties = {
        path = { type = "string", description = "Absolute path or path relative to the project root" },
        start_line = { type = "integer", description = "First line, 1-based" },
        end_line = { type = "integer", description = "Last line, inclusive" },
      },
      required = { "path" },
    },
  },
  {
    name = "workspace_search",
    description = "Search project text with a literal fixed-string query. Results are capped.",
    parameters = {
      type = "object",
      properties = {
        query = { type = "string", description = "Literal text to find" },
        glob = { type = "string", description = "Optional ripgrep file glob such as *.zig" },
      },
      required = { "query" },
    },
  },
}

local function realpath(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

local function within(path, root)
  return path == root or vim.startswith(path, root .. "/")
end

local function position_params(session)
  if not vim.api.nvim_win_is_valid(session.source.winid) then
    return nil
  end
  local clients = vim.lsp.get_clients({ bufnr = session.source.bufnr })
  if #clients == 0 then
    return nil
  end
  return vim.lsp.util.make_position_params(session.source.winid, clients[1].offset_encoding)
end

local function flatten_results(responses)
  local results = {}
  for _, response in pairs(responses or {}) do
    if response.result then
      if vim.islist(response.result) then
        vim.list_extend(results, response.result)
      else
        results[#results + 1] = response.result
      end
    end
  end
  return results
end

local function location_of(item)
  if item.uri or item.targetUri then
    return item
  end
  return item.location
end

local function format_locations(session, responses)
  local output = {}
  for _, item in ipairs(flatten_results(responses)) do
    local location = location_of(item)
    local uri = location and (location.uri or location.targetUri)
    local range = location and (location.range or location.targetSelectionRange)
    if uri and uri:match("^file:") then
      local path = realpath(vim.uri_to_fname(uri))
      session.allowed[path] = true
      output[#output + 1] = {
        name = item.name,
        path = path,
        line = range and range.start.line + 1 or nil,
        character = range and range.start.character + 1 or nil,
      }
      if #output >= session.opts.max_tool_results then
        break
      end
    end
  end
  return vim.json.encode(output)
end

local function hover_text(responses)
  for _, item in ipairs(flatten_results(responses)) do
    local contents = item.contents
    if type(contents) == "string" then
      return contents
    elseif type(contents) == "table" and contents.value then
      return contents.value
    elseif type(contents) == "table" then
      local parts = {}
      for _, part in ipairs(contents) do
        parts[#parts + 1] = type(part) == "string" and part or part.value or ""
      end
      return table.concat(parts, "\n")
    end
  end
  return "No hover information returned."
end

local function lsp_request(session, method, params, formatter, callback)
  local supported = false
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = session.source.bufnr })) do
    supported = supported or client:supports_method(method, session.source.bufnr)
  end
  if not supported then
    callback(("The attached LSP does not support %s."):format(method))
    return
  end
  vim.lsp.buf_request_all(session.source.bufnr, method, params, function(responses)
    local ok, result = pcall(formatter, session, responses)
    callback(ok and result or ("Tool formatting failed: %s"):format(result))
  end)
end

local function decode_arguments(call)
  local arguments = call["function"] and call["function"].arguments or "{}"
  local ok, decoded = pcall(vim.json.decode, arguments ~= "" and arguments or "{}")
  if not ok or type(decoded) ~= "table" then
    return nil, "Invalid JSON tool arguments: " .. tostring(arguments)
  end
  return decoded
end

local function read_source(session, args, callback)
  if type(args.path) ~= "string" or args.path == "" then
    callback("read_source requires a path.")
    return
  end
  local path = args.path
  if not vim.startswith(path, "/") then
    path = vim.fs.joinpath(session.root, path)
  end
  path = realpath(path)
  if not within(path, session.root) and not session.allowed[path] then
    callback("Access denied: the path is outside the project and was not returned by the LSP.")
    return
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    callback("Could not read " .. path)
    return
  end
  local first = math.max(1, tonumber(args.start_line) or 1)
  local requested_last = tonumber(args.end_line) or (first + session.opts.max_tool_lines - 1)
  local last = math.min(#lines, requested_last, first + session.opts.max_tool_lines - 1)
  local selected = first <= #lines and vim.list_slice(lines, first, last) or {}
  callback(("%s:%d-%d\n%s"):format(path, first, last, table.concat(selected, "\n")))
end

local function workspace_search(session, args, callback)
  if type(args.query) ~= "string" or args.query == "" then
    callback("workspace_search requires a non-empty literal query.")
    return
  end
  local command = {
    "rg",
    "--line-number",
    "--column",
    "--no-heading",
    "--color",
    "never",
    "--fixed-strings",
  }
  if type(args.glob) == "string" and args.glob ~= "" then
    vim.list_extend(command, { "--glob", args.glob })
  end
  vim.list_extend(command, { "--", args.query, session.root })
  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 and result.code ~= 1 then
        callback("Workspace search failed: " .. vim.trim(result.stderr or "unknown error"))
        return
      end
      local lines = vim.split(result.stdout or "", "\n", { trimempty = true })
      if #lines > session.opts.max_tool_results then
        lines = vim.list_slice(lines, 1, session.opts.max_tool_results)
        lines[#lines + 1] = "…results truncated…"
      end
      callback(#lines > 0 and table.concat(lines, "\n") or "No matches found.")
    end)
  end)
end

function M.schemas()
  local tools = {}
  for _, schema in ipairs(schemas) do
    tools[#tools + 1] = { type = "function", ["function"] = vim.deepcopy(schema) }
  end
  return tools
end

function M.new(source, context, opts)
  local filename = realpath(context.filename)
  local root = vim.fs.root(filename, { ".git" }) or vim.fs.dirname(filename) or vim.fn.getcwd()
  root = realpath(root)
  local allowed = { [filename] = true }
  if context.definition then
    allowed[realpath(context.definition.filename)] = true
  end
  return { source = source, context = context, opts = opts, root = root, allowed = allowed }
end

function M.execute(session, call, callback)
  local args, decode_err = decode_arguments(call)
  if not args then
    callback(decode_err)
    return
  end
  local name = call["function"] and call["function"].name
  local position_tools = {
    lsp_hover = true,
    lsp_definition = true,
    lsp_references = true,
    lsp_type_definition = true,
    lsp_implementation = true,
  }
  local params = position_tools[name] and position_params(session) or nil
  if position_tools[name] and not params then
    callback("The original source position is no longer available.")
    return
  end
  if name == "lsp_hover" then
    lsp_request(session, methods.textDocument_hover, params, function(_, responses)
      return hover_text(responses)
    end, callback)
  elseif name == "lsp_definition" then
    lsp_request(session, methods.textDocument_definition, params, format_locations, callback)
  elseif name == "lsp_references" then
    params.context = { includeDeclaration = true }
    lsp_request(session, methods.textDocument_references, params, format_locations, callback)
  elseif name == "lsp_type_definition" then
    lsp_request(session, methods.textDocument_typeDefinition, params, format_locations, callback)
  elseif name == "lsp_implementation" then
    lsp_request(session, methods.textDocument_implementation, params, format_locations, callback)
  elseif name == "lsp_workspace_symbols" then
    lsp_request(session, methods.workspace_symbol, { query = args.query or "" }, format_locations, callback)
  elseif name == "read_source" then
    read_source(session, args, callback)
  elseif name == "workspace_search" then
    workspace_search(session, args, callback)
  else
    callback("Unknown or disallowed tool: " .. tostring(name))
  end
end

return M

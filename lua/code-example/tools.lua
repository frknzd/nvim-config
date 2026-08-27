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
    name = "source_search",
    description = "Search project and LSP-discovered source trees with literal or regex queries. Returns each "
      .. "match's path, line number, and surrounding source. Use this to find declarations, call sites, and "
      .. "standard library implementation details. Prefer queries to try related alternatives in one call.",
    parameters = {
      type = "object",
      properties = {
        query = { type = "string", description = "Text or regular expression to find" },
        queries = {
          type = "array",
          description = "Alternative searches to run together, instead of query",
          items = { type = "string" },
          minItems = 1,
          maxItems = 4,
        },
        mode = {
          type = "string",
          enum = { "literal", "regex" },
          description = "Search mode; defaults to literal",
        },
        glob = { type = "string", description = "Optional ripgrep file glob such as *.zig" },
        path = {
          type = "string",
          description = "Optional project-relative path or searchable absolute source path",
        },
      },
    },
  },
  {
    name = "source_outline",
    description = "List declarations with locations from a project or LSP-discovered source file. Use this to "
      .. "discover the actual methods and associated types of an unfamiliar API before searching for usages.",
    parameters = {
      type = "object",
      properties = {
        path = {
          type = "string",
          description = "Source file; defaults to the selected symbol's definition file",
        },
        query = { type = "string", description = "Optional literal filter for declaration lines" },
      },
    },
  },
  {
    name = "web_search",
    description = "Search the public web for current documentation, API references, or facts that are not "
      .. "available from the project or the LSP. Returns titles, URLs, and short snippets. Use when accuracy "
      .. "depends on external, up-to-date information; do not use it for anything answerable from local source. "
      .. "Follow up with web_fetch on the most relevant result to read past the snippet.",
    parameters = {
      type = "object",
      properties = { query = { type = "string", description = "Search query" } },
      required = { "query" },
    },
  },
  {
    name = "web_fetch",
    description = "Fetch a web page and return its readable text, for depth beyond a web_search snippet. Use "
      .. "on a URL returned by web_search (or another page it links to) when the snippet is not enough.",
    parameters = {
      type = "object",
      properties = { url = { type = "string", description = "Absolute http(s) URL" } },
      required = { "url" },
    },
  },
}

local function realpath(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

local function within(path, root)
  return path == root or vim.startswith(path, root .. "/")
end

local function add_search_root(roots, candidate)
  for root in pairs(roots) do
    if within(candidate, root) then
      return
    end
    if within(root, candidate) then
      roots[root] = nil
    end
  end
  roots[candidate] = true
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
      add_search_root(session.search_roots, vim.fs.dirname(path))
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

local function searchable(session, path)
  for root in pairs(session.search_roots) do
    if within(path, root) then
      return true
    end
  end
  return false
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
  if not searchable(session, path) and not session.allowed[path] then
    callback("Access denied: the path is outside the project and LSP-discovered source trees.")
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

local function search_paths(session, requested)
  local roots = {}
  if type(requested) == "string" and requested ~= "" then
    local path = requested
    if not vim.startswith(path, "/") then
      path = vim.fs.joinpath(session.root, path)
    end
    path = realpath(path)
    if not searchable(session, path) then
      return nil, "Access denied: path is outside the project and LSP-discovered source trees."
    end
    roots[1] = path
  else
    for root in pairs(session.search_roots) do
      roots[#roots + 1] = root
    end
    table.sort(roots)
  end
  return roots
end

local function search_queries(args)
  local queries = {}
  if type(args.query) == "string" and args.query ~= "" then
    queries[1] = args.query
  elseif vim.islist(args.queries) then
    for _, query in ipairs(args.queries) do
      if type(query) == "string" and query ~= "" then
        queries[#queries + 1] = query
        if #queries == 4 then
          break
        end
      end
    end
  end
  return queries
end

local function format_search_result(query, result, limit, context)
  if result.code ~= 0 and result.code ~= 1 then
    return ("Search `%s` failed: %s"):format(query, vim.trim(result.stderr or "unknown error")), 0
  end
  local matches = vim.split(result.stdout or "", "\n", { trimempty = true })
  local output = {}
  local seen = {}
  for _, match in ipairs(matches) do
    local path, line_number = match:match("^(.-):(%d+):")
    line_number = tonumber(line_number)
    local key = path and line_number and (path .. ":" .. line_number) or nil
    if key and not seen[key] then
      seen[key] = true
      local ok, source = pcall(vim.fn.readfile, path)
      if ok then
        local first = math.max(1, line_number - context)
        local last = math.min(#source, line_number + context)
        local excerpt = { key }
        for number = first, last do
          local marker = number == line_number and ">" or " "
          excerpt[#excerpt + 1] = ("%s %5d | %s"):format(marker, number, source[number])
        end
        output[#output + 1] = table.concat(excerpt, "\n")
        if #output >= limit then
          break
        end
      end
    end
  end
  if #output == 0 then
    return ("No matches found for `%s`."):format(query), 0
  end
  if #matches > #output then
    output[#output + 1] = "…additional matches omitted…"
  end
  return ("Search: `%s`\n\n%s"):format(query, table.concat(output, "\n\n")), #output
end

local function source_search(session, args, callback)
  local queries = search_queries(args)
  if #queries == 0 then
    callback("source_search requires query or a non-empty queries list.")
    return
  end
  local roots, roots_err = search_paths(session, args.path)
  if not roots then
    callback(roots_err)
    return
  end
  local mode = args.mode == "regex" and "regex" or "literal"
  local pending = #queries
  local results = {}
  for index, query in ipairs(queries) do
    local command = {
      "rg",
      "--line-number",
      "--with-filename",
      "--no-heading",
      "--color",
      "never",
    }
    if mode == "literal" then
      command[#command + 1] = "--fixed-strings"
    end
    if type(args.glob) == "string" and args.glob ~= "" then
      vim.list_extend(command, { "--glob", args.glob })
    end
    vim.list_extend(command, { "--", query })
    vim.list_extend(command, roots)
    vim.system(command, { text = true }, function(result)
      results[index] = result
      pending = pending - 1
      if pending > 0 then
        return
      end
      vim.schedule(function()
        local total_limit = session.opts.max_search_results or session.opts.max_tool_results
        local query_limit = math.max(1, math.floor(total_limit / #queries))
        local context = session.opts.search_context_lines or 8
        local output = {}
        local found = 0
        for result_index, item in ipairs(results) do
          local formatted, count = format_search_result(queries[result_index], item, query_limit, context)
          output[#output + 1] = formatted
          found = found + count
        end
        if found == 0 then
          output[#output + 1] = "Searched:\n- " .. table.concat(roots, "\n- ")
          output[#output + 1] = "Try a shorter identifier, a declaration regex, or source_outline."
        end
        callback(table.concat(output, "\n\n"))
      end)
    end)
  end
end

local declaration_patterns = {
  "^pub%s+fn%s+",
  "^fn%s+",
  "^pub%s+const%s+",
  "^pub%s+var%s+",
  "^pub%s+struct%s+",
  "^pub%s+enum%s+",
  "^pub%s+union%s+",
  "^pub%s+opaque%s+",
  "^pub%s+trait%s+",
  "^pub%s+type%s+",
  "^export%s+async%s+function%s+",
  "^export%s+function%s+",
  "^async%s+function%s+",
  "^function%s+",
  "^local%s+function%s+",
  "^export%s+class%s+",
  "^export%s+interface%s+",
  "^export%s+type%s+",
  "^export%s+enum%s+",
  "^class%s+",
  "^interface%s+",
  "^struct%s+",
  "^enum%s+",
  "^union%s+",
  "^trait%s+",
  "^impl%s+",
  "^async%s+def%s+",
  "^def%s+",
  "^class%s+",
  "^func%s+",
  "^type%s+",
}

local function declaration_line(line)
  local trimmed = vim.trim(line)
  for _, pattern in ipairs(declaration_patterns) do
    if trimmed:match(pattern) then
      return true
    end
  end
  return false
end

local function source_outline(session, args, callback)
  local requested = type(args.path) == "string" and args.path or nil
  local path = requested or (session.context.definition and session.context.definition.filename)
  if not path then
    callback("source_outline requires a path when no definition source is available.")
    return
  end
  if not vim.startswith(path, "/") then
    path = vim.fs.joinpath(session.root, path)
  end
  path = realpath(path)
  if not searchable(session, path) then
    callback("Access denied: path is outside the project and LSP-discovered source trees.")
    return
  end
  local ok, source = pcall(vim.fn.readfile, path)
  if not ok then
    callback("Could not read " .. path)
    return
  end
  local filter = type(args.query) == "string" and args.query or nil
  local output = { path }
  local limit = session.opts.max_tool_results
  for number, line in ipairs(source) do
    if declaration_line(line) and (not filter or line:find(filter, 1, true)) then
      output[#output + 1] = ("%5d | %s"):format(number, vim.trim(line))
      if #output > limit then
        output[#output + 1] = "…additional declarations omitted…"
        break
      end
    end
  end
  if #output == 1 then
    output[#output + 1] = filter and ("No declarations matching `%s` found."):format(filter)
      or "No recognizable declarations found."
  end
  callback(table.concat(output, "\n"))
end

local function strip_tags(html)
  local text = html:gsub("<[^>]*>", "")
  text = text
    :gsub("&amp;", "&")
    :gsub("&quot;", '"')
    :gsub("&#0?39;", "'")
    :gsub("&#x27;", "'")
    :gsub("&lt;", "<")
    :gsub("&gt;", ">")
    :gsub("&nbsp;", " ")
  return vim.trim(text)
end

local function decode_uddg(href)
  local encoded = href:match("uddg=([^&]+)")
  if not encoded then
    return href
  end
  encoded = encoded:gsub("+", " ")
  encoded = encoded:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  return encoded
end

local function parse_web_results(html, max_results)
  local results = {}
  for href, title in html:gmatch('<a[^>]-class="result__a"[^>]-href="(.-)"[^>]->(.-)</a>') do
    results[#results + 1] = { url = decode_uddg(href), title = strip_tags(title) }
    if #results >= max_results then
      break
    end
  end
  local index = 0
  for snippet in html:gmatch('<a[^>]-class="result__snippet"[^>]->(.-)</a>') do
    index = index + 1
    if not results[index] then
      break
    end
    results[index].snippet = strip_tags(snippet)
  end
  return results
end

local function web_search(session, args, callback)
  if type(args.query) ~= "string" or args.query == "" then
    callback("web_search requires a non-empty query.")
    return
  end
  local command = {
    "curl",
    "--silent",
    "--show-error",
    "--connect-timeout",
    "5",
    "--max-time",
    "15",
    "--user-agent",
    "Mozilla/5.0 (compatible; nvim-code-example)",
    "--get",
    "--data-urlencode",
    "q=" .. args.query,
    "https://html.duckduckgo.com/html/",
  }
  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback("Web search failed: " .. vim.trim(result.stderr or "unknown error"))
        return
      end
      local max_results = session.opts.max_search_results or session.opts.max_tool_results
      local results = parse_web_results(result.stdout or "", max_results)
      if #results == 0 then
        callback("No web results found.")
        return
      end
      local lines = {}
      for i, item in ipairs(results) do
        lines[#lines + 1] = ("%d. %s\n   %s\n   %s"):format(i, item.title, item.url, item.snippet or "")
      end
      callback(table.concat(lines, "\n\n"))
    end)
  end)
end

local function extract_page_text(html)
  local text = html
  text = text:gsub("<%s*[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.-<%s*/%s*[Ss][Cc][Rr][Ii][Pp][Tt]%s*>", " ")
  text = text:gsub("<%s*[Ss][Tt][Yy][Ll][Ee][^>]*>.-<%s*/%s*[Ss][Tt][Yy][Ll][Ee]%s*>", " ")
  text = text:gsub("<%s*[Bb][Rr]%s*/?>", "\n")
  text = text:gsub("<%s*/%s*[PpLlIiTtDdHh][1-6]?%s*>", "\n")
  text = strip_tags(text)
  text = text:gsub("[ \t]+", " ")
  text = text:gsub(" ?\n ?", "\n")
  text = text:gsub("\n\n\n+", "\n\n")
  return vim.trim(text)
end

local function web_fetch(session, args, callback)
  if type(args.url) ~= "string" or not args.url:match("^https?://") then
    callback("web_fetch requires an absolute http(s) URL.")
    return
  end
  local command = {
    "curl",
    "--silent",
    "--show-error",
    "--location",
    "--max-redirs",
    "5",
    "--connect-timeout",
    "5",
    "--max-time",
    "20",
    "--user-agent",
    "Mozilla/5.0 (compatible; nvim-code-example)",
    "--",
    args.url,
  }
  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback("Fetch failed: " .. vim.trim(result.stderr or "unknown error"))
        return
      end
      local text = extract_page_text(result.stdout or "")
      callback(text ~= "" and text or "No readable text extracted from the page.")
    end)
  end)
end

function M.schemas(disabled)
  local tools = {}
  for _, schema in ipairs(schemas) do
    if not (disabled and disabled[schema.name]) then
      tools[#tools + 1] = { type = "function", ["function"] = vim.deepcopy(schema) }
    end
  end
  return tools
end

function M.new(source, context, opts)
  local filename = realpath(context.filename)
  local root = vim.fs.root(filename, { ".git" }) or vim.fs.dirname(filename) or vim.fn.getcwd()
  root = realpath(root)
  local allowed = { [filename] = true }
  local search_roots = { [root] = true }
  if context.definition then
    local definition = realpath(context.definition.filename)
    allowed[definition] = true
    add_search_root(search_roots, vim.fs.dirname(definition))
  end
  return {
    source = source,
    context = context,
    opts = opts,
    root = root,
    allowed = allowed,
    search_roots = search_roots,
  }
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
  elseif name == "source_search" then
    source_search(session, args, callback)
  elseif name == "source_outline" then
    source_outline(session, args, callback)
  elseif name == "web_search" then
    web_search(session, args, callback)
  elseif name == "web_fetch" then
    web_fetch(session, args, callback)
  else
    callback("Unknown or disallowed tool: " .. tostring(name))
  end
end

return M

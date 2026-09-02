-- Clojure and ClojureScript share one Neovim filetype (`clojure`), so Conjure
-- gives .clj, .cljs and .cljc a single client and therefore a single REPL
-- connection. `:ConjureClientState` splits that into independently named
-- states, each holding its own connection, and this keys the state off the
-- file extension: .clj/.cljc talk to the JVM nREPL, .cljs talks to the
-- shadow-cljs nREPL, and neither disturbs the other.
--
-- Conjure resolves every setting from `vim.b` before `vim.g`, which is what
-- makes this work: the port file a buffer looks for is set buffer-locally
-- rather than globally, so the two states never race for the same file.
--
-- Deliberately NOT setting `conjure#log#linked_to_client_state`. Giving each
-- state its own log buffer sounds tidier but loses results: `log.append`
-- batches lines per *filetype* and the 100ms flush timer resolves the log
-- buffer's name from whichever state key is current when it fires, not the one
-- the result was produced under. With one shared log there is only ever one
-- buffer to resolve, and Conjure still prefixes each evaluation with a
-- `; State: <key>` header once more than one state exists.

local port_files = {
  jvm = { ".nrepl-port" },
  cljs = { ".shadow-cljs/nrepl.port" },
}

return {
  {
    "Olical/conjure",
    optional = true,
    init = function()
      -- Conjure otherwise spawns `bb nrepl-server` whenever it finds no port
      -- file, silently connecting you to a babashka REPL that knows nothing
      -- about the project. Failing to connect is the more useful outcome.
      vim.g["conjure#client#clojure#nrepl#connection#auto_repl#enabled"] = false

      local group = vim.api.nvim_create_augroup("conjure_state_by_extension", { clear = true })

      vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
        group = group,
        pattern = { "*.clj", "*.cljs", "*.cljc", "*.edn" },
        callback = function(event)
          -- Conjure's log buffer is named `conjure-log-<pid>.cljc`, which
          -- matches the `*.cljc` pattern above. Reading the log must not
          -- reassign the REPL of whatever you were just editing.
          if vim.startswith(vim.fn.fnamemodify(event.file, ":t"), "conjure-log-") then
            return
          end

          -- Only real file buffers: terminals, quickfix and plugin scratch
          -- buffers have no business choosing a REPL.
          if vim.bo[event.buf].buftype ~= "" then
            return
          end

          local state = vim.endswith(event.file, ".cljs") and "cljs" or "jvm"

          -- Buffer-local, so each buffer resolves its own REPL.
          vim.b[event.buf]["conjure#client#clojure#nrepl#connection#port_files"] = port_files[state]

          -- The client state key is global, so it has to be re-asserted every
          -- time we enter a buffer. Skip the command when it already matches,
          -- otherwise every buffer switch writes a line to the log.
          if vim.g.conjure_state_key ~= state then
            vim.g.conjure_state_key = state
            vim.cmd("ConjureClientState " .. state)
          end
        end,
      })
    end,
  },
}

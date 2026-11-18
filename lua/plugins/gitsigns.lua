return {
  {
    "lewis6991/gitsigns.nvim",
    opts = function(_, opts)
      local on_attach = opts.on_attach
      opts.on_attach = function(bufnr)
        if on_attach and on_attach(bufnr) == false then
          return false
        end

        local gs = require("gitsigns")
        local comparing_origin = false
        local pending = false
        vim.keymap.set("n", "<leader>gho", function()
          if pending then
            return
          end

          local base
          local next_origin = not comparing_origin
          if next_origin then
            -- Match the merge-base comparison used by Snacks' <leader>gD.
            local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr))
            local result = vim.system({ "git", "-C", dir, "merge-base", "HEAD", "origin" }, { text = true }):wait()
            if result.code ~= 0 then
              vim.notify("Could not find a merge base with origin: " .. vim.trim(result.stderr or ""), vim.log.levels.WARN)
              return
            end
            base = vim.trim(result.stdout)
          end

          pending = true
          gs.change_base(base, false, vim.schedule_wrap(function(err)
            pending = false
            if err then
              vim.notify(tostring(err), vim.log.levels.WARN)
              return
            end
            comparing_origin = next_origin
            vim.notify(comparing_origin and "Git signs: comparing with origin merge base" or "Git signs: comparing with index")
          end))
        end, { buffer = bufnr, desc = "Toggle Origin Diff Signs" })
      end
    end,
  },
}

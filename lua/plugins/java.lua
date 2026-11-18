-- jdtls itself runs on the default Java (26), but the Gradle import must use
-- Java 17: zap-extensions/zaproxy use Gradle 8.13, which cannot run on Java 26
-- ("Unsupported class file major version 70"). Without this the project never
-- imports and every file is "not on the classpath".
local jdk17 = "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"

return {
  {
    "mfussenegger/nvim-jdtls",
    opts = function(_, opts)
      -- zap-extensions has 100+ Gradle projects: give jdtls more memory.
      table.insert(opts.cmd, "--jvm-arg=-Xmx4G")

      -- Scanning every project for main classes is slow on large repos.
      opts.dap_main = false

      opts.settings = vim.tbl_deep_extend("force", opts.settings or {}, {
        java = {
          import = { gradle = { java = { home = jdk17 } } },
          configuration = {
            runtimes = {
              { name = "JavaSE-17", path = jdk17, default = true },
            },
          },
        },
      })

      -- nvim-jdtls only sends `settings` after startup, but jdtls starts the
      -- Gradle import during initialize. Pass them as initializationOptions too,
      -- or the first import still runs on Java 26.
      opts.jdtls = vim.tbl_deep_extend("force", opts.jdtls or {}, {
        init_options = { settings = opts.settings },
      })
    end,
  },
}

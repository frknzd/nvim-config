# 💤 LazyVim

A starter template for [LazyVim](https://github.com/LazyVim/LazyVim).
Refer to the [documentation](https://lazyvim.github.io/installation) to get started.

## Annotated code examples

Press `<leader>ce` on a symbol to open a streamed, LSP-informed example in a Markdown float. An attached language
server and [llama.cpp](https://github.com/ggml-org/llama.cpp) are required:

```sh
brew install llama.cpp
```

The first request downloads the configured Qwen3.5-4B GGUF (about 2.8 GB) into llama.cpp's cache. The plugin owns
the server it starts, stops it after ten idle minutes or when Neovim exits, and never stops a server configured via
the `endpoint` option. Use `:CodeExampleStop` to stop it manually; inside the float, press `r` to regenerate or `q`
to close and cancel the active request.

The model can inspect code through bounded tools for LSP hover, definitions, references, type definitions,
implementations, and workspace symbols, plus literal workspace search and source reading. Source reads are limited to
the project or files returned by the LSP, search results and line ranges are capped, and no arbitrary shell tool is
exposed. Tool calls and abbreviated results appear in the Model Activity pane.

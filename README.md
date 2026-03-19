# snipbrowzurr.nvim

Browse, preview, and expand LuaSnip snippets via fzf-lua (falls back to `vim.ui.select`).

## Requirements

- [LuaSnip](https://github.com/L3MON4D3/LuaSnip)
- [fzf-lua](https://github.com/ibhagwan/fzf-lua) _(optional but recommended)_

## Installation

```lua
-- lazy.nvim
{
    "blaze-d83/snipbrowzurr.nvim",
    dependencies = { "L3MON4D3/LuaSnip", "ibhagwan/fzf-lua" },
    config = function()
        require("snipbrowzurr").setup()
    end,
}
```

## Setup

```lua
require("snipbrowzurr").setup({
    keymap          = "<leader>ss",  -- false to disable
    view            = "list",        -- "list" | "two-column"
    preview         = true,
    load_vscode     = true,          -- auto-load LuaSnip loaders
    load_lua        = true,
    load_snipmate   = true,
    on_select       = nil,           -- function(entry, ctx) return true to suppress expansion
})
```

All options are optional. `setup()` must be called.

## Usage

| Key / call | Action |
|---|---|
| `<leader>ss` | Open browser for current filetype |
| `<Enter>` | Expand snippet at cursor |
| `Ctrl-y` | Yank snippet body to `+` |
| `M.open({ filetype = "python" })` | Browse a specific filetype |
| `M.clear_cache()` | Bust snippet cache |

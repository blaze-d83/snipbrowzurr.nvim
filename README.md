# snipbrowzurr

Tiny plugin to quickly browse snippets set for the current file-type.


# Installation and setup guide

### lazy.nvim
Add the plugin to your 'lazy' spec (example minimal):
```lua
{
    "blaze-d83/snipbrowzurr.nvim",
    branch = "stable"
    config = function()
        require("snipbrowzurr").setup({ keymap = "<leader>sp" })
    end,
}
```

### packer.nvim
```lua
use {
    'blaze-d83/snipbrowzurr.nvim',
    tag = "stable"
    config = function()
        require('snippet_browser').setup({ keymap = '<leader>sp' })
    end
}
```

# Configuration
```lua
-- Defaults
opts = {
    load_vscode = true,
    load_lua = true,
    load_snipmate = true,
    keymap = "<leader>ss",
}
```

# Contribution

Please submit your issues and PRs. Thank you!

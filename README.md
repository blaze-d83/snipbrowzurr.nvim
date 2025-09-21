# snipbrowzurr

Tiny plugin to quickly browse snippets set for the current file-type.

# Screenshots


# Installation and setup guide

### lazy.nvim
Add the plugin to your 'lazy' spec (example minimal):
```lua
{
    "blaze-d83/snipbrowzurr.nvim",
    config = function()
        require("snipbrowzurr").setup({ keymap = "<leader>sp" })
    end,
}
```

### packer.nvim
```lua
use {
    'blaze-d83/snipbrowzurr.nvim',
    config = function()
        require('snippet_browser').setup({ keymap = '<leader>sp' })
    end
}
```

# Contribution

Please submit your issues and PRs. Thank you!

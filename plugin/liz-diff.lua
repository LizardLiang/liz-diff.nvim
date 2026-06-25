vim.api.nvim_create_user_command('LizDiff', function()
  require('liz_diff').open()
end, { desc = 'Open liz-diff floating window' })

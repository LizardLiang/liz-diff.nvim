vim.api.nvim_create_user_command('LizDiff', function()
  require('liz-diff').open()
end, { desc = 'Open liz-diff floating window' })

vim.api.nvim_create_user_command('LizDiff', function()
  require('liz_diff').open()
end, { desc = 'Open liz-diff floating window' })

vim.api.nvim_create_user_command('LizDiffFile', function(o)
  local ref = (o.args ~= '') and o.args or 'HEAD'
  require('liz_diff').open_current(ref)
end, { nargs = '?', desc = 'liz-diff: diff current file vs HEAD (working left, commit right)' })

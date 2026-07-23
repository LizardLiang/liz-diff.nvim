vim.api.nvim_create_user_command('LizDiff', function()
  require('liz_diff').open()
end, { desc = 'Open liz-diff floating window' })

vim.api.nvim_create_user_command('LizDiffFile', function(o)
  local ref = (o.args ~= '') and o.args or 'HEAD'
  require('liz_diff').open_current(ref)
end, { nargs = '?', desc = 'liz-diff: diff current file vs HEAD (working left, commit right)' })

vim.api.nvim_create_user_command('LizDiffPaths', function()
  require('liz_diff').paths()
end, { desc = "liz-diff: blink both diff panes' absolute paths for ~2s" })

vim.api.nvim_create_user_command('LizDiffNext', function()
  require('liz_diff').next()
end, { desc = 'liz-diff: diff the next file in the list' })

vim.api.nvim_create_user_command('LizDiffPrev', function()
  require('liz_diff').prev()
end, { desc = 'liz-diff: diff the previous file in the list' })

vim.api.nvim_create_user_command('LizDiffAdd', function()
  require('liz_diff').add()
end, { desc = 'liz-diff: stage the current file into the compare list' })

vim.api.nvim_create_user_command('LizDiffCompare', function()
  require('liz_diff').compare()
end, { desc = 'liz-diff: diff the two staged compare-list files (left/right)' })

vim.api.nvim_create_user_command('LizDiffList', function()
  require('liz_diff').list()
end, { desc = 'liz-diff: show the staged compare-list files' })

vim.api.nvim_create_user_command('LizDiffClear', function()
  require('liz_diff').clear()
  vim.notify('liz-diff: compare list cleared', vim.log.levels.INFO)
end, { desc = 'liz-diff: clear the compare list' })

-- <Plug> maps for the compare flow, bound to no default key so users opt in
-- (matches the plugin's no-global-keymap stance). Non-recursive so a user's
-- own nmap to <Plug>(LizDiffAdd) / <Plug>(LizDiffCompare) can't recurse.
vim.keymap.set('n', '<Plug>(LizDiffAdd)', function() require('liz_diff').add() end, { noremap = true })
vim.keymap.set('n', '<Plug>(LizDiffCompare)', function() require('liz_diff').compare() end, { noremap = true })

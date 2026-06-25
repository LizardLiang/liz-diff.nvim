require('tests.helpers')

describe('liz-diff.diff', function()
  -- diff.lua is heavily Neovim-API dependent (nvim_open_win, diffthis, vsplit).
  -- These are contract tests — they define the expected behavior for integration testing.

  pending('open() with Modified file opens vimdiff with ref left, working right')
  pending('open() with Added file opens vimdiff with empty left pane')
  pending('open() with Deleted file opens vimdiff with empty right pane')
  pending('open() with Renamed file uses old_path for reference content')
  pending('open() with binary file shows notify and returns without opening diff')
  pending('open() with empty reference uses index (staged) as old side')
  pending('reference buffer has buftype=nofile and bufhidden=wipe')
  pending('reference buffer name follows liz-diff://<ref>/<path> convention')
  pending('reference buffer filetype matches source file extension')
  pending('cleanup_previous() wipes tracked reference buffers no longer in a window')
end)

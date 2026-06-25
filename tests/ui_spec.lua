require('tests.helpers')

describe('liz-diff.ui', function()
  local ui

  before_each(function()
    package.loaded['liz_diff.ui'] = nil
    ui = require('liz_diff.ui')
  end)

  describe('format_line()', function()
    it('formats a modified file', function()
      local line = ui.format_line({
        status = 'M',
        filepath = 'lua/liz-diff/init.lua',
        insertions = 24,
        deletions = 8,
        binary = false,
      })
      assert.is_string(line)
      assert.truthy(line:find('M'))
      assert.truthy(line:find('lua/liz%-diff/init%.lua'))
      assert.truthy(line:find('%+24'))
      assert.truthy(line:find('%-8'))
    end)

    it('formats an added file with zero deletions', function()
      local line = ui.format_line({
        status = 'A',
        filepath = 'new.lua',
        insertions = 15,
        deletions = 0,
        binary = false,
      })
      assert.truthy(line:find('A'))
      assert.truthy(line:find('new%.lua'))
      assert.truthy(line:find('%+15'))
      assert.truthy(line:find('%-0'))
    end)

    it('formats a deleted file', function()
      local line = ui.format_line({
        status = 'D',
        filepath = 'old.lua',
        insertions = 0,
        deletions = 42,
        binary = false,
      })
      assert.truthy(line:find('D'))
      assert.truthy(line:find('%-42'))
    end)

    it('formats a renamed file', function()
      local line = ui.format_line({
        status = 'R',
        filepath = 'after.lua',
        old_path = 'before.lua',
        insertions = 5,
        deletions = 3,
        binary = false,
      })
      assert.truthy(line:find('R'))
      assert.truthy(line:find('after%.lua'))
    end)

    it('formats a binary file', function()
      local line = ui.format_line({
        status = 'M',
        filepath = 'image.png',
        insertions = 0,
        deletions = 0,
        binary = true,
      })
      assert.truthy(line:find('image%.png'))
    end)
  end)

  describe('is_open()', function()
    it('returns false when no windows are open', function()
      assert.is_false(ui.is_open())
    end)
  end)

  -- Integration tests for open/close/set_results require Neovim runtime.
  -- Mark as pending for TDD — implement when running under plenary/vusted.

  pending('open() creates prompt and results windows')
  pending('close() cleans up both windows and buffers')
  pending('set_results() populates results buffer')
  pending('set_error() shows error in results buffer')
  pending('set_empty() shows no-changes message')
  pending('get_cursor_index() returns 1-based line position')
  pending('prompt <CR> triggers on_submit callback')
  pending('results <CR> triggers on_select callback')
  pending('close keys close the float')
  pending('focus moves to results after submit')
  pending('i or / in results refocuses prompt')
end)

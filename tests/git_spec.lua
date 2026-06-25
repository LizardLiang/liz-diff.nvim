require('tests.helpers')

describe('liz-diff.git', function()
  local git

  before_each(function()
    package.loaded['liz_diff.git'] = nil
    git = require('liz_diff.git')
  end)

  -- Parsing tests target the internal parse functions.
  -- If the module doesn't export them, we test through the public diff() callback.
  -- For TDD, we define the expected parsing contract here.

  describe('parse_name_status()', function()
    it('parses Modified file', function()
      local result = git.parse_name_status({ 'M\tlua/liz-diff/init.lua' })
      assert.are.equal(1, #result)
      assert.are.equal('M', result[1].status)
      assert.are.equal('lua/liz-diff/init.lua', result[1].filepath)
      assert.is_nil(result[1].old_path)
    end)

    it('parses Added file', function()
      local result = git.parse_name_status({ 'A\tlua/liz-diff/new.lua' })
      assert.are.equal(1, #result)
      assert.are.equal('A', result[1].status)
      assert.are.equal('lua/liz-diff/new.lua', result[1].filepath)
    end)

    it('parses Deleted file', function()
      local result = git.parse_name_status({ 'D\tlua/liz-diff/old.lua' })
      assert.are.equal(1, #result)
      assert.are.equal('D', result[1].status)
      assert.are.equal('lua/liz-diff/old.lua', result[1].filepath)
    end)

    it('parses Renamed file with score', function()
      local result = git.parse_name_status({ 'R100\told/path.lua\tnew/path.lua' })
      assert.are.equal(1, #result)
      assert.are.equal('R', result[1].status)
      assert.are.equal('new/path.lua', result[1].filepath)
      assert.are.equal('old/path.lua', result[1].old_path)
    end)

    it('parses Renamed file with partial score', function()
      local result = git.parse_name_status({ 'R075\ta.lua\tb.lua' })
      assert.are.equal(1, #result)
      assert.are.equal('R', result[1].status)
      assert.are.equal('b.lua', result[1].filepath)
      assert.are.equal('a.lua', result[1].old_path)
    end)

    it('parses multiple files', function()
      local lines = {
        'M\tsrc/init.lua',
        'A\tsrc/new.lua',
        'D\tsrc/old.lua',
        'R100\tsrc/before.lua\tsrc/after.lua',
      }
      local result = git.parse_name_status(lines)
      assert.are.equal(4, #result)
      assert.are.equal('M', result[1].status)
      assert.are.equal('A', result[2].status)
      assert.are.equal('D', result[3].status)
      assert.are.equal('R', result[4].status)
    end)

    it('skips empty lines', function()
      local result = git.parse_name_status({ 'M\ta.lua', '', 'A\tb.lua' })
      assert.are.equal(2, #result)
    end)

    it('returns empty table for empty input', function()
      local result = git.parse_name_status({})
      assert.are.equal(0, #result)
    end)
  end)

  describe('parse_numstat()', function()
    it('parses normal file with insertions and deletions', function()
      local result = git.parse_numstat({ '24\t8\tlua/liz-diff/init.lua' })
      assert.are.equal(1, #result)
      assert.are.equal('lua/liz-diff/init.lua', result[1].filepath)
      assert.are.equal(24, result[1].insertions)
      assert.are.equal(8, result[1].deletions)
      assert.is_false(result[1].binary)
    end)

    it('parses file with zero deletions', function()
      local result = git.parse_numstat({ '15\t0\tlua/liz-diff/new.lua' })
      assert.are.equal(15, result[1].insertions)
      assert.are.equal(0, result[1].deletions)
    end)

    it('parses binary file (dashes for both columns)', function()
      local result = git.parse_numstat({ '-\t-\timage.png' })
      assert.are.equal(1, #result)
      assert.are.equal('image.png', result[1].filepath)
      assert.are.equal(0, result[1].insertions)
      assert.are.equal(0, result[1].deletions)
      assert.is_true(result[1].binary)
    end)

    it('normalizes simple rename path (old => new)', function()
      local result = git.parse_numstat({ '5\t3\told.lua => new.lua' })
      assert.are.equal(1, #result)
      assert.are.equal('new.lua', result[1].filepath)
      assert.are.equal(5, result[1].insertions)
      assert.are.equal(3, result[1].deletions)
    end)

    it('normalizes brace rename path ({old => new}/suffix)', function()
      local result = git.parse_numstat({ '2\t1\tsrc/{old-name => new-name}/init.lua' })
      assert.are.equal(1, #result)
      assert.are.equal('src/new-name/init.lua', result[1].filepath)
      assert.are.equal(2, result[1].insertions)
      assert.are.equal(1, result[1].deletions)
    end)

    it('parses multiple files', function()
      local lines = {
        '24\t8\tsrc/init.lua',
        '15\t0\tsrc/new.lua',
        '-\t-\tassets/logo.png',
      }
      local result = git.parse_numstat(lines)
      assert.are.equal(3, #result)
      assert.is_false(result[1].binary)
      assert.is_false(result[2].binary)
      assert.is_true(result[3].binary)
    end)

    it('skips empty lines', function()
      local result = git.parse_numstat({ '10\t5\ta.lua', '', '3\t1\tb.lua' })
      assert.are.equal(2, #result)
    end)

    it('returns empty table for empty input', function()
      local result = git.parse_numstat({})
      assert.are.equal(0, #result)
    end)
  end)

  describe('merge_results()', function()
    it('merges name-status and numstat by filepath', function()
      local name_status = {
        { status = 'M', filepath = 'init.lua' },
        { status = 'A', filepath = 'new.lua' },
      }
      local numstat = {
        { filepath = 'init.lua', insertions = 24, deletions = 8, binary = false },
        { filepath = 'new.lua', insertions = 15, deletions = 0, binary = false },
      }
      local result = git.merge_results(name_status, numstat)
      assert.are.equal(2, #result)

      assert.are.equal('M', result[1].status)
      assert.are.equal('init.lua', result[1].filepath)
      assert.are.equal(24, result[1].insertions)
      assert.are.equal(8, result[1].deletions)

      assert.are.equal('A', result[2].status)
      assert.are.equal('new.lua', result[2].filepath)
      assert.are.equal(15, result[2].insertions)
      assert.are.equal(0, result[2].deletions)
    end)

    it('handles rename with old_path preserved', function()
      local name_status = {
        { status = 'R', filepath = 'new.lua', old_path = 'old.lua' },
      }
      local numstat = {
        { filepath = 'new.lua', insertions = 5, deletions = 3, binary = false },
      }
      local result = git.merge_results(name_status, numstat)
      assert.are.equal(1, #result)
      assert.are.equal('R', result[1].status)
      assert.are.equal('old.lua', result[1].old_path)
      assert.are.equal(5, result[1].insertions)
    end)

    it('defaults to 0 counts when file only in name-status', function()
      local name_status = {
        { status = 'M', filepath = 'orphan.lua' },
      }
      local numstat = {}
      local result = git.merge_results(name_status, numstat)
      assert.are.equal(1, #result)
      assert.are.equal(0, result[1].insertions)
      assert.are.equal(0, result[1].deletions)
      assert.is_false(result[1].binary)
    end)

    it('defaults to M status when file only in numstat', function()
      local name_status = {}
      local numstat = {
        { filepath = 'orphan.lua', insertions = 10, deletions = 2, binary = false },
      }
      local result = git.merge_results(name_status, numstat)
      assert.are.equal(1, #result)
      assert.are.equal('M', result[1].status)
      assert.are.equal(10, result[1].insertions)
    end)

    it('handles binary flag from numstat', function()
      local name_status = {
        { status = 'M', filepath = 'image.png' },
      }
      local numstat = {
        { filepath = 'image.png', insertions = 0, deletions = 0, binary = true },
      }
      local result = git.merge_results(name_status, numstat)
      assert.are.equal(1, #result)
      assert.is_true(result[1].binary)
    end)

    it('returns empty table when both inputs are empty', function()
      local result = git.merge_results({}, {})
      assert.are.equal(0, #result)
    end)

    it('preserves name-status ordering', function()
      local name_status = {
        { status = 'D', filepath = 'z.lua' },
        { status = 'A', filepath = 'a.lua' },
        { status = 'M', filepath = 'm.lua' },
      }
      local numstat = {
        { filepath = 'a.lua', insertions = 1, deletions = 0, binary = false },
        { filepath = 'm.lua', insertions = 2, deletions = 1, binary = false },
        { filepath = 'z.lua', insertions = 0, deletions = 10, binary = false },
      }
      local result = git.merge_results(name_status, numstat)
      assert.are.equal('z.lua', result[1].filepath)
      assert.are.equal('a.lua', result[2].filepath)
      assert.are.equal('m.lua', result[3].filepath)
    end)
  end)

  describe('is_git_repo()', function()
    -- These tests require vim.fn.system mock
    -- Included as contract tests; actual behavior tested in integration

    it('returns true when inside a git work tree', function()
      vim.fn.system = function() return 'true\n' end
      vim.v = { shell_error = 0 }
      assert.is_true(git.is_git_repo())
    end)

    it('returns false when not a git repo', function()
      vim.fn.system = function() return '' end
      vim.v = { shell_error = 128 }
      assert.is_false(git.is_git_repo())
    end)
  end)
end)

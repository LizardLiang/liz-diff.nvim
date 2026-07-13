require('tests.helpers')

-- Captured before any `it()` runs (describe bodies execute immediately at
-- file load; it/before_each bodies are deferred). Several tests below
-- permanently overwrite vim.fn.system / vim.v to mock git output — the
-- real-git integration tests further down restore these originals so they
-- observe genuine shell_error / system() results regardless of test order.
local REAL_SYSTEM = vim.fn.system
local REAL_VIM_V = vim.v

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

  describe('is_new_file()', function()
    it('returns true when path is absent at a valid ref', function()
      vim.fn.system = function() return '' end
      vim.v = { shell_error = 0 }
      assert.is_true(git.is_new_file('/repo', 'HEAD', 'src/new.tsx'))
    end)

    it('returns false when path exists at the ref', function()
      vim.fn.system = function() return '100644 blob abc123\tsrc/exists.lua\n' end
      vim.v = { shell_error = 0 }
      assert.is_false(git.is_new_file('/repo', 'HEAD', 'src/exists.lua'))
    end)

    it('returns false when the ref does not resolve', function()
      vim.fn.system = function() return '' end
      vim.v = { shell_error = 128 }
      assert.is_false(git.is_new_file('/repo', 'BADREF', 'src/x.lua'))
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

  describe('append_untracked()', function()
    it('appends untracked entries after tracked results', function()
      local files = { { status = 'M', filepath = 'a.lua' } }
      local untracked = { { status = 'A', filepath = 'b.lua' } }
      local result = git.append_untracked(files, untracked)
      assert.are.equal(2, #result)
      assert.are.equal('a.lua', result[1].filepath)
      assert.are.equal('b.lua', result[2].filepath)
    end)

    it('skips an untracked path already present in tracked results', function()
      local files = { { status = 'M', filepath = 'a.lua' } }
      local untracked = {
        { status = 'A', filepath = 'a.lua' },
        { status = 'A', filepath = 'c.lua' },
      }
      local result = git.append_untracked(files, untracked)
      assert.are.equal(2, #result)
      assert.are.equal('a.lua', result[1].filepath)
      assert.are.equal('c.lua', result[2].filepath)
    end)

    it('returns tracked results unchanged when there are no untracked entries', function()
      local files = { { status = 'M', filepath = 'a.lua' } }
      local result = git.append_untracked(files, {})
      assert.are.equal(1, #result)
      assert.are.equal('a.lua', result[1].filepath)
    end)
  end)

  -- Real-filesystem / real-git integration tests for the untracked-files
  -- feature. Restores REAL_SYSTEM / REAL_VIM_V first, since earlier tests in
  -- this file permanently overwrite vim.fn.system / vim.v with mocks.
  describe('untracked files integration', function()
    local tmp_dir
    local prev_cwd

    local function write_file(path, content)
      local f = assert(io.open(path, 'wb'))
      f:write(content)
      f:close()
    end

    local function sh(args)
      local out = vim.fn.system(args)
      assert.are.equal(0, vim.v.shell_error, 'command failed: ' .. table.concat(args, ' ') .. '\n' .. tostring(out))
      return out
    end

    before_each(function()
      vim.fn.system = REAL_SYSTEM
      vim.v = REAL_VIM_V

      tmp_dir = vim.fn.tempname()
      vim.fn.mkdir(tmp_dir, 'p')
      prev_cwd = vim.fn.getcwd()
      vim.fn.chdir(tmp_dir)

      sh({ 'git', 'init', '-q' })
      sh({ 'git', 'config', 'user.email', 'test@example.com' })
      sh({ 'git', 'config', 'user.name', 'test' })
    end)

    after_each(function()
      vim.fn.chdir(prev_cwd)
      vim.fn.delete(tmp_dir, 'rf')
    end)

    describe('list_untracked()', function()
      it('lists untracked files, respecting .gitignore, incl. a path with a space', function()
        write_file('.gitignore', '*.log\n')
        write_file('ignored.log', 'x')
        write_file('plain.txt', 'hello\n')
        write_file('file with space.txt', 'hi\n')

        local done, err, paths
        git.list_untracked(function(e, p)
          err, paths, done = e, p, true
        end)
        assert.is_true(vim.wait(3000, function() return done end))

        assert.is_nil(err)
        table.sort(paths)
        assert.are.same({ '.gitignore', 'file with space.txt', 'plain.txt' }, paths)
      end)

      it('returns an empty list when there are no untracked files', function()
        local done, err, paths
        git.list_untracked(function(e, p)
          err, paths, done = e, p, true
        end)
        assert.is_true(vim.wait(3000, function() return done end))

        assert.is_nil(err)
        assert.are.equal(0, #paths)
      end)
    end)

    describe('untracked_stats()', function()
      it('counts lines for a file with a trailing newline', function()
        write_file('a.txt', 'line1\nline2\nline3\n')
        local entries = git.untracked_stats({ 'a.txt' })
        assert.are.equal(1, #entries)
        assert.are.equal('A', entries[1].status)
        assert.are.equal('a.txt', entries[1].filepath)
        assert.are.equal(3, entries[1].insertions)
        assert.are.equal(0, entries[1].deletions)
        assert.is_false(entries[1].binary)
      end)

      it('counts a final fragment without a trailing newline as a line', function()
        write_file('b.txt', 'line1\nline2')
        local entries = git.untracked_stats({ 'b.txt' })
        assert.are.equal(2, entries[1].insertions)
      end)

      it('detects binary files via a NUL byte in the first 8KB', function()
        write_file('bin.dat', 'abc\0def')
        local entries = git.untracked_stats({ 'bin.dat' })
        assert.is_true(entries[1].binary)
        assert.are.equal(0, entries[1].insertions)
      end)

      it('returns a zero-count entry for an empty file', function()
        write_file('empty.txt', '')
        local entries = git.untracked_stats({ 'empty.txt' })
        assert.are.equal(0, entries[1].insertions)
        assert.is_false(entries[1].binary)
      end)
    end)

    describe('diff() with untracked files', function()
      local function run_diff(reference)
        local done, err, files
        git.diff(reference, function(e, f)
          err, files, done = e, f, true
        end)
        assert.is_true(vim.wait(3000, function() return done end))
        return err, files
      end

      local function find(files, filepath)
        for _, f in ipairs(files) do
          if f.filepath == filepath then
            return f
          end
        end
        return nil
      end

      it('includes untracked and staged-new files for the empty prompt against HEAD', function()
        write_file('tracked.txt', 'v1\n')
        sh({ 'git', 'add', 'tracked.txt' })
        sh({ 'git', 'commit', '-q', '-m', 'init' })
        write_file('tracked.txt', 'v1\nv2\n')
        write_file('untracked.txt', 'brand new\n')
        write_file('staged.txt', 'staged\n')
        sh({ 'git', 'add', 'staged.txt' })

        local err, files = run_diff('')
        assert.is_nil(err)

        local tracked_mod = find(files, 'tracked.txt')
        assert.is_not_nil(tracked_mod)
        assert.are.equal('M', tracked_mod.status)

        local staged_new = find(files, 'staged.txt')
        assert.is_not_nil(staged_new)
        assert.are.equal('A', staged_new.status)

        local untracked = find(files, 'untracked.txt')
        assert.is_not_nil(untracked)
        assert.are.equal('A', untracked.status)
      end)

      it('falls back to a bare diff on an unborn HEAD and still includes untracked files', function()
        write_file('loose.txt', 'x\n')

        local err, files = run_diff('')
        assert.is_nil(err)

        local loose = find(files, 'loose.txt')
        assert.is_not_nil(loose)
        assert.are.equal('A', loose.status)
      end)

      it('excludes untracked files for a two-dot commit range', function()
        sh({ 'git', 'commit', '-q', '--allow-empty', '-m', 'init' })
        sh({ 'git', 'branch', 'base' })
        sh({ 'git', 'commit', '-q', '--allow-empty', '-m', 'second' })
        write_file('untracked.txt', 'x\n')

        local err, files = run_diff('base..HEAD')
        assert.is_nil(err)
        assert.is_nil(find(files, 'untracked.txt'))
      end)

      it('excludes untracked files for a three-dot commit range', function()
        sh({ 'git', 'commit', '-q', '--allow-empty', '-m', 'init' })
        sh({ 'git', 'branch', 'base' })
        sh({ 'git', 'commit', '-q', '--allow-empty', '-m', 'second' })
        write_file('untracked.txt', 'x\n')

        local err, files = run_diff('base...HEAD')
        assert.is_nil(err)
        assert.is_nil(find(files, 'untracked.txt'))
      end)
    end)
  end)
end)

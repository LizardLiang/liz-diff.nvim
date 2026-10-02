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

  describe('empty_message()', function()
    it('describes the empty prompt as all uncommitted changes', function()
      assert.are.equal('No uncommitted changes found', ui.empty_message(''))
    end)

    it('names the reference for a non-empty, unmatched reference', function()
      assert.are.equal('No changes found for main', ui.empty_message('main'))
    end)
  end)

  describe('filter_files()', function()
    local function f(path)
      return { status = 'M', filepath = path, insertions = 1, deletions = 0, binary = false }
    end

    local files = {
      f('lua/liz-diff/init.lua'),
      f('lua/liz-diff/UI.lua'),
      f('README.md'),
      f('docs/guide.md'),
      f('tests/init.test.lua'),
      f('Makefile'),
    }

    local function paths(list)
      local out = {}
      for _, file in ipairs(list) do
        out[#out + 1] = file.filepath
      end
      return out
    end

    it('returns every file for an empty or blank query', function()
      assert.are.equal(6, #ui.filter_files(files, ''))
      assert.are.equal(6, #ui.filter_files(files, '   '))
      assert.are.equal(6, #ui.filter_files(files, nil))
    end)

    it('matches a name term as a substring of the full path', function()
      assert.are.same({ 'docs/guide.md' }, paths(ui.filter_files(files, 'docs')))
      assert.are.same({ 'lua/liz-diff/init.lua', 'tests/init.test.lua' }, paths(ui.filter_files(files, 'init')))
    end)

    it('is case-insensitive for names and paths', function()
      assert.are.same({ 'README.md' }, paths(ui.filter_files(files, 'readme')))
      assert.are.same({ 'lua/liz-diff/UI.lua' }, paths(ui.filter_files(files, 'ui.LUA')))
    end)

    it('matches a .ext term against the end of the path', function()
      assert.are.same({ 'README.md', 'docs/guide.md' }, paths(ui.filter_files(files, '.md')))
      assert.are.equal(0, #ui.filter_files(files, '.mak'))
    end)

    it('treats *.ext like .ext', function()
      assert.are.same({ 'README.md', 'docs/guide.md' }, paths(ui.filter_files(files, '*.md')))
    end)

    it('ORs multiple extension terms', function()
      assert.are.same(
        { 'lua/liz-diff/init.lua', 'lua/liz-diff/UI.lua', 'README.md', 'docs/guide.md', 'tests/init.test.lua' },
        paths(ui.filter_files(files, '.lua .md'))
      )
    end)

    it('ANDs a name term with an extension term', function()
      assert.are.same({ 'lua/liz-diff/init.lua', 'tests/init.test.lua' }, paths(ui.filter_files(files, 'init .lua')))
      assert.are.same({ 'tests/init.test.lua' }, paths(ui.filter_files(files, 'tests .lua')))
    end)

    it('ANDs multiple name terms', function()
      assert.are.same({ 'lua/liz-diff/init.lua' }, paths(ui.filter_files(files, 'liz init')))
    end)

    it('treats special characters in name terms literally', function()
      assert.are.same({ 'lua/liz-diff/init.lua', 'lua/liz-diff/UI.lua' }, paths(ui.filter_files(files, 'liz-diff')))
      assert.are.same({ 'tests/init.test.lua' }, paths(ui.filter_files(files, 't.test')))
      assert.are.equal(0, #ui.filter_files(files, 'init.l.a'))
      assert.are.equal(0, #ui.filter_files(files, '%'))
      assert.are.equal(0, #ui.filter_files(files, '[a-z]'))
    end)

    it('matches a multi-dot extension against the path end', function()
      assert.are.same({ 'tests/init.test.lua' }, paths(ui.filter_files(files, '.test.lua')))
    end)

    it('preserves the original order', function()
      local ordered = ui.filter_files({ f('b.lua'), f('a.lua'), f('c.lua') }, '.lua')
      assert.are.same({ 'b.lua', 'a.lua', 'c.lua' }, paths(ordered))
    end)
  end)

  describe('no_match_message()', function()
    it('quotes the trimmed query', function()
      assert.are.equal('No files match "foo .lua"', ui.no_match_message('  foo .lua '))
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
  pending('i in results refocuses prompt')
end)

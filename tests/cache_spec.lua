require('tests.helpers')

describe('liz-diff.cache', function()
  local cache

  before_each(function()
    package.loaded['liz_diff.cache'] = nil
    cache = require('liz_diff.cache')
  end)

  describe('get()', function()
    it('returns nil for unknown keyword', function()
      assert.is_nil(cache.get('nonexistent'))
    end)

    it('returns nil for empty string keyword when not set', function()
      assert.is_nil(cache.get(''))
    end)
  end)

  describe('set()', function()
    it('stores files and initializes cursor_index to 1', function()
      local files = {
        { status = 'M', filepath = 'init.lua', insertions = 10, deletions = 3, binary = false },
      }
      cache.set('main', files)
      local entry = cache.get('main')
      assert.is_not_nil(entry)
      assert.are.equal(1, entry.cursor_index)
      assert.are.equal(1, #entry.files)
      assert.are.equal('M', entry.files[1].status)
    end)

    it('stores empty string as valid key', function()
      local files = {
        { status = 'A', filepath = 'new.lua', insertions = 5, deletions = 0, binary = false },
      }
      cache.set('', files)
      local entry = cache.get('')
      assert.is_not_nil(entry)
      assert.are.equal(1, #entry.files)
    end)

    it('overwrites existing entry for same keyword', function()
      cache.set('main', {
        { status = 'M', filepath = 'a.lua', insertions = 1, deletions = 1, binary = false },
      })
      cache.set('main', {
        { status = 'A', filepath = 'b.lua', insertions = 2, deletions = 0, binary = false },
        { status = 'D', filepath = 'c.lua', insertions = 0, deletions = 5, binary = false },
      })
      local entry = cache.get('main')
      assert.are.equal(2, #entry.files)
      assert.are.equal('A', entry.files[1].status)
      assert.are.equal(1, entry.cursor_index)
    end)

    it('stores multiple keywords independently', function()
      cache.set('main', {
        { status = 'M', filepath = 'a.lua', insertions = 1, deletions = 1, binary = false },
      })
      cache.set('dev', {
        { status = 'A', filepath = 'b.lua', insertions = 2, deletions = 0, binary = false },
      })
      assert.are.equal('M', cache.get('main').files[1].status)
      assert.are.equal('A', cache.get('dev').files[1].status)
    end)
  end)

  describe('set_cursor()', function()
    it('updates cursor_index for existing keyword', function()
      cache.set('main', {
        { status = 'M', filepath = 'a.lua', insertions = 1, deletions = 1, binary = false },
        { status = 'A', filepath = 'b.lua', insertions = 2, deletions = 0, binary = false },
      })
      cache.set_cursor('main', 2)
      assert.are.equal(2, cache.get('main').cursor_index)
    end)

    it('does nothing for non-existent keyword', function()
      cache.set_cursor('nonexistent', 5)
      assert.is_nil(cache.get('nonexistent'))
    end)
  end)

  describe('clear()', function()
    it('removes all cached entries', function()
      cache.set('main', {
        { status = 'M', filepath = 'a.lua', insertions = 1, deletions = 1, binary = false },
      })
      cache.set('dev', {
        { status = 'A', filepath = 'b.lua', insertions = 2, deletions = 0, binary = false },
      })
      cache.clear()
      assert.is_nil(cache.get('main'))
      assert.is_nil(cache.get('dev'))
    end)

    it('works when cache is already empty', function()
      cache.clear()
      assert.is_nil(cache.get('anything'))
    end)
  end)
end)

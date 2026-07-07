require('tests.helpers')

describe('liz-diff.config', function()
  local config

  before_each(function()
    package.loaded['liz_diff.config'] = nil
    config = require('liz_diff.config')
  end)

  describe('get()', function()
    it('returns default config when no merge has been called', function()
      local cfg = config.get()
      assert.are.equal(0.8, cfg.width)
      assert.are.equal(0.6, cfg.height)
      assert.are.equal('rounded', cfg.border)
      assert.are.same({ '<Esc>', 'q' }, cfg.keymap.close)
      assert.are.equal('<CR>', cfg.keymap.open_diff)
      assert.are.equal('R', cfg.keymap.refresh)
    end)

    it('returns the same reference on successive calls', function()
      local a = config.get()
      local b = config.get()
      assert.are.equal(a, b)
    end)
  end)

  describe('merge()', function()
    it('overrides a top-level scalar', function()
      config.merge({ width = 0.5 })
      assert.are.equal(0.5, config.get().width)
    end)

    it('preserves unspecified defaults', function()
      config.merge({ width = 0.5 })
      assert.are.equal(0.6, config.get().height)
      assert.are.equal('rounded', config.get().border)
    end)

    it('deep-merges nested keymap table', function()
      config.merge({ keymap = { close = { 'x' } } })
      assert.are.same({ 'x' }, config.get().keymap.close)
      assert.are.equal('<CR>', config.get().keymap.open_diff)
    end)

    it('overrides border style', function()
      config.merge({ border = 'single' })
      assert.are.equal('single', config.get().border)
    end)

    it('handles nil input gracefully', function()
      config.merge(nil)
      assert.are.equal(0.8, config.get().width)
    end)

    it('handles empty table input', function()
      config.merge({})
      assert.are.equal(0.8, config.get().width)
      assert.are.equal(0.6, config.get().height)
    end)
  end)
end)

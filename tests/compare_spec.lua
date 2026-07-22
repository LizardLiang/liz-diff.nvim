require('tests.helpers')

describe('liz-diff.compare', function()
  local compare

  before_each(function()
    package.loaded['liz_diff.compare'] = nil
    compare = require('liz_diff.compare')
  end)

  describe('normalize()', function()
    it('collapses relative/separator variants to one form', function()
      local a = compare.normalize('a.lua')
      local b = compare.normalize('./a.lua')
      assert.are.equal(a, b)
    end)

    it('returns an absolute path', function()
      local norm = compare.normalize('a.lua')
      assert.are.equal(vim.fn.fnamemodify(norm, ':p'), norm)
    end)

    -- Platform-gated: vim.fs.normalize alone only uppercases the drive
    -- letter, so case-folding is only applied on Windows (case-insensitive
    -- NTFS); Unix paths must stay case-sensitive and distinct.
    it('case-folds on Windows only; stays case-sensitive on Unix', function()
      local upper = compare.normalize('A.lua')
      local lower = compare.normalize('a.lua')
      if vim.fn.has('win32') == 1 then
        assert.are.equal(lower, upper)
      else
        assert.are_not.equal(lower, upper)
      end
    end)
  end)

  describe('stage()', function()
    it('adds the first file and reports 1 slot filled', function()
      local result = compare.stage('a.lua')
      assert.are.equal('added', result)
      assert.are.equal(1, #compare.get())
    end)

    it('adds a second distinct file and completes the pair', function()
      compare.stage('a.lua')
      local result = compare.stage('b.lua')
      assert.are.equal('added', result)
      assert.are.equal(2, #compare.get())
    end)

    it('rejects a duplicate (same normalized path) without mutating', function()
      compare.stage('a.lua')
      local result = compare.stage('./a.lua')
      assert.are.equal('duplicate', result)
      assert.are.equal(1, #compare.get())
    end)

    -- Platform-gated: on Windows (case-insensitive NTFS), staging 'A.lua'
    -- then 'a.lua' must resolve to the same on-disk file and be rejected as
    -- a duplicate — otherwise both compare-list slots silently point at the
    -- same file and :LizDiffCompare self-diffs. On Unix, the two paths are
    -- genuinely distinct files, so both stage.
    it('treats a case-differing path to the same file as a duplicate on Windows', function()
      compare.stage('A.lua')
      local result = compare.stage('a.lua')
      if vim.fn.has('win32') == 1 then
        assert.are.equal('duplicate', result)
        assert.are.equal(1, #compare.get())
      else
        assert.are.equal('added', result)
        assert.are.equal(2, #compare.get())
      end
    end)

    it('returns full for a third distinct file without mutating', function()
      compare.stage('a.lua')
      compare.stage('b.lua')
      local before = compare.get()
      local result = compare.stage('c.lua')
      assert.are.equal('full', result)
      assert.are.same(before, compare.get())
    end)
  end)

  describe('replace()', function()
    before_each(function()
      compare.stage('a.lua')
      compare.stage('b.lua')
    end)

    it('replaces slot 1, leaving slot 2 unchanged', function()
      local result = compare.replace(1, 'c.lua')
      assert.are.equal('replaced', result)
      local staged = compare.get()
      assert.are.equal(compare.normalize('c.lua'), staged[1])
      assert.are.equal(compare.normalize('b.lua'), staged[2])
    end)

    it('replaces slot 2, leaving slot 1 unchanged', function()
      local result = compare.replace(2, 'c.lua')
      assert.are.equal('replaced', result)
      local staged = compare.get()
      assert.are.equal(compare.normalize('a.lua'), staged[1])
      assert.are.equal(compare.normalize('c.lua'), staged[2])
    end)

    it('rejects a value equal to the OTHER slot as a duplicate', function()
      local result = compare.replace(1, 'b.lua')
      assert.are.equal('duplicate', result)
      local staged = compare.get()
      assert.are.equal(compare.normalize('a.lua'), staged[1])
      assert.are.equal(compare.normalize('b.lua'), staged[2])
    end)
  end)

  describe('get()/clear()', function()
    it('get() returns a copy, not the live list', function()
      compare.stage('a.lua')
      local staged = compare.get()
      staged[#staged + 1] = 'mutated'
      assert.are.equal(1, #compare.get())
    end)

    it('clear() empties the list', function()
      compare.stage('a.lua')
      compare.stage('b.lua')
      compare.clear()
      assert.are.equal(0, #compare.get())
    end)
  end)

  -- add() guards: mocks nvim_buf_get_name / vim.bo so the buffer-shape checks
  -- are exercised without standing up real Neovim buffers, mirroring
  -- diff.open_current's guard sequence (same testing boundary the plan calls
  -- for: pure core + notify contracts, not live diff splits).
  describe('add() guards', function()
    local orig_get_name, orig_bo, orig_notify
    local notified, level

    before_each(function()
      orig_get_name = vim.api.nvim_buf_get_name
      orig_bo = vim.bo
      orig_notify = vim.notify
      notified, level = nil, nil
      vim.notify = function(msg, lvl) notified, level = msg, lvl end
    end)

    after_each(function()
      vim.api.nvim_buf_get_name = orig_get_name
      vim.bo = orig_bo
      vim.notify = orig_notify
    end)

    it('no-ops with INFO when the current buffer has no file name', function()
      vim.api.nvim_buf_get_name = function() return '' end
      vim.bo = setmetatable({}, { __index = function() return { buftype = '' } end })

      compare.add()

      assert.are.equal(0, #compare.get())
      assert.are.equal('liz-diff: no file in current buffer', notified)
      assert.are.equal(vim.log.levels.INFO, level)
    end)

    it('no-ops with INFO for a liz-diff:// reference buffer', function()
      vim.api.nvim_buf_get_name = function() return 'liz-diff://HEAD/a.lua' end
      vim.bo = setmetatable({}, { __index = function() return { buftype = '' } end })

      compare.add()

      assert.are.equal(0, #compare.get())
      assert.is_not_nil(notified:find('liz%-diff reference buffer'))
      assert.are.equal(vim.log.levels.INFO, level)
    end)

    it('no-ops with INFO for a non-empty buftype (e.g. a scratch buffer)', function()
      vim.api.nvim_buf_get_name = function() return '/some/fake-name.lua' end
      vim.bo = setmetatable({}, { __index = function() return { buftype = 'nofile' } end })

      compare.add()

      assert.are.equal(0, #compare.get())
      assert.are.equal('liz-diff: no file in current buffer', notified)
      assert.are.equal(vim.log.levels.INFO, level)
    end)

    it('stages a real-looking file buffer and notifies (1/2)', function()
      vim.api.nvim_buf_get_name = function() return 'a.lua' end
      vim.bo = setmetatable({}, { __index = function() return { buftype = '' } end })

      compare.add()

      assert.are.equal(1, #compare.get())
      assert.is_not_nil(notified:find('%(1/2%)'))
      assert.are.equal(vim.log.levels.INFO, level)
    end)

    it('notifies duplicate without mutating when the same file is added twice', function()
      vim.api.nvim_buf_get_name = function() return 'a.lua' end
      vim.bo = setmetatable({}, { __index = function() return { buftype = '' } end })

      compare.add()
      compare.add()

      assert.are.equal(1, #compare.get())
      assert.is_not_nil(notified:find('already staged'))
    end)
  end)

  describe('compare() guard', function()
    local orig_notify
    local notified, level

    before_each(function()
      orig_notify = vim.notify
      notified, level = nil, nil
      vim.notify = function(msg, lvl) notified, level = msg, lvl end
    end)

    after_each(function()
      vim.notify = orig_notify
    end)

    it('no-ops with INFO reporting the count when fewer than two files are staged', function()
      compare.compare()
      assert.are.equal('liz-diff: need two files to compare, 0 staged', notified)
      assert.are.equal(vim.log.levels.INFO, level)

      notified = nil
      compare.stage('a.lua')
      compare.compare()
      assert.are.equal('liz-diff: need two files to compare, 1 staged', notified)
    end)
  end)

  describe('compare() missing-file guard', function()
    local orig_notify, orig_fs_stat
    local notified, level

    before_each(function()
      orig_notify = vim.notify
      orig_fs_stat = vim.uv.fs_stat
      notified, level = nil, nil
      vim.notify = function(msg, lvl) notified, level = msg, lvl end
    end)

    after_each(function()
      vim.notify = orig_notify
      vim.uv.fs_stat = orig_fs_stat
    end)

    it('warns and aborts when a staged file no longer exists on disk', function()
      compare.stage('a.lua')
      compare.stage('b.lua')
      vim.uv.fs_stat = function() return nil end

      compare.compare()

      assert.are.equal(vim.log.levels.WARN, level)
      assert.is_not_nil(notified:find('no longer exists'))
    end)
  end)
end)

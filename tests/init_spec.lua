require('tests.helpers')

describe('liz-diff.init', function()
  -- Orchestration tests require Neovim runtime for full integration.
  -- Pure-logic behaviors tested here via mocks where possible.

  describe('setup()', function()
    it('merges user config into defaults', function()
      package.loaded['liz_diff'] = nil
      package.loaded['liz_diff.config'] = nil

      local liz_diff = require('liz_diff')
      liz_diff.setup({ width = 0.5, border = 'single' })

      local config = require('liz_diff.config')
      assert.are.equal(0.5, config.get().width)
      assert.are.equal('single', config.get().border)
      assert.are.equal(0.6, config.get().height)
    end)

    it('works without arguments', function()
      package.loaded['liz_diff'] = nil
      package.loaded['liz_diff.config'] = nil

      local liz_diff = require('liz_diff')
      liz_diff.setup()

      local config = require('liz_diff.config')
      assert.are.equal(0.8, config.get().width)
    end)
  end)

  describe('wrap_index()', function()
    local liz_diff

    before_each(function()
      liz_diff = require('tests.helpers').reset_module('liz_diff')
    end)

    it('leaves an in-range index unchanged', function()
      assert.are.equal(1, liz_diff.wrap_index(1, 3))
      assert.are.equal(2, liz_diff.wrap_index(2, 3))
      assert.are.equal(3, liz_diff.wrap_index(3, 3))
    end)

    it('wraps forward past the last index to the first', function()
      assert.are.equal(1, liz_diff.wrap_index(4, 3))
      assert.are.equal(2, liz_diff.wrap_index(5, 3))
    end)

    it('wraps backward before the first index to the last', function()
      assert.are.equal(3, liz_diff.wrap_index(0, 3))
      assert.are.equal(2, liz_diff.wrap_index(-1, 3))
    end)

    it('always returns 1 for a single-file list', function()
      assert.are.equal(1, liz_diff.wrap_index(1, 1))
      assert.are.equal(1, liz_diff.wrap_index(2, 1))
      assert.are.equal(1, liz_diff.wrap_index(0, 1))
    end)

    it('returns nil for an empty or nil list length', function()
      assert.is_nil(liz_diff.wrap_index(1, 0))
      assert.is_nil(liz_diff.wrap_index(1, nil))
    end)
  end)

  describe('next()/prev() with no active list', function()
    it('notifies at INFO and does not dispatch a diff', function()
      local liz_diff = require('tests.helpers').reset_module('liz_diff')
      local notified, level
      local orig = vim.notify
      vim.notify = function(msg, lvl) notified, level = msg, lvl end

      liz_diff.next()
      assert.are.equal('liz-diff: no active file list', notified)
      assert.are.equal(vim.log.levels.INFO, level)

      notified = nil
      liz_diff.prev()
      assert.are.equal('liz-diff: no active file list', notified)

      vim.notify = orig
    end)
  end)

  -- M.resolve_open_mode() is the routing rule behind the `:LizDiff` range-open
  -- fix: it decides, per file open, whether to dispatch through diff.open_pr,
  -- diff.open_commits (the new two-commit pane shared with the PR flow), or
  -- the original diff.open (working-tree LEFT / reference RIGHT — valid for a
  -- single ref only). 'range-unresolved' is the case that used to silently
  -- fall through to diff.open and hit the `<range>:<path>` git show bug this
  -- fix removes; open_file_at (untestable here — needs a live nav session)
  -- turns it into a notify-only no-op instead.
  describe('resolve_open_mode()', function()
    local liz_diff

    before_each(function()
      liz_diff = require('tests.helpers').reset_module('liz_diff')
    end)

    it('routes to "pr" when a PR/MR session is active, regardless of keyword shape', function()
      assert.are.equal('pr', liz_diff.resolve_open_mode({ n = 12 }, nil, '#12'))
    end)

    it('routes to "range" when a range has already been resolved', function()
      local range = { base_rev = 'a', head_rev = 'b', label = 'a..b' }
      assert.are.equal('range', liz_diff.resolve_open_mode(nil, range, 'a..b'))
    end)

    it('routes to "range-unresolved" for a range keyword with no resolved range', function()
      assert.are.equal('range-unresolved', liz_diff.resolve_open_mode(nil, nil, 'a...b'))
      assert.are.equal('range-unresolved', liz_diff.resolve_open_mode(nil, nil, 'main..HEAD'))
    end)

    it('routes to "ref" for a plain single-ref keyword', function()
      assert.are.equal('ref', liz_diff.resolve_open_mode(nil, nil, 'main'))
    end)

    it('routes to "ref" for the empty-prompt keyword', function()
      assert.are.equal('ref', liz_diff.resolve_open_mode(nil, nil, ''))
    end)

    it('prefers "pr" over a stale current_range from a previous session', function()
      local range = { base_rev = 'a', head_rev = 'b' }
      assert.are.equal('pr', liz_diff.resolve_open_mode({ n = 1 }, range, '#1'))
    end)
  end)

  -- Integration tests for open() flow
  pending('open() aborts with notify when not in git repo')
  pending('open() closes existing float before opening (toggle)')
  pending('on_submit always re-runs git.diff (no cache short-circuit)')
  pending('on_submit with cache miss triggers git.diff async')
  pending('on_submit cancels in-flight jobs before dispatching new ones')
  pending('staleness guard: late callback for old keyword does not update UI')
  pending('staleness guard: late callback for old keyword still caches result')
  pending('on_select saves cursor position to cache')
  pending('on_select closes float and opens vimdiff')
  pending('empty keyword triggers unstaged diff')
  pending('refresh key re-runs git.diff for current ref preserving cursor')
  pending('refresh is a no-op when no ref submitted yet')

  -- Repo-root threading (tactical plan step 2 / spec-delta "Repo-Root Scoped
  -- List Diffs"): root is resolved once per run_diff fetch, cached alongside
  -- files/meta, and restored on a cache-backed reopen.
  pending('on_select passes the root resolved at fetch time to diff.open / diff.open_pr')
  pending('run_diff aborts with a loud error when repo root cannot be resolved')
  pending('reopening from cache restores the root recorded at fetch time')

  -- File navigation (diff-file-navigation): next/prev dispatch through the same
  -- diff.open / diff.open_pr path on_select uses; requires real windows/buffers.
  pending('next() opens the following file and prev() the preceding one')
  pending('next() on the last file wraps to the first; prev() on the first wraps to the last')
  pending('navigating syncs the cached cursor so a picker reopen lands on the current file')
  pending('PR-flow session dispatches through diff.open_pr with the captured PR context')
end)

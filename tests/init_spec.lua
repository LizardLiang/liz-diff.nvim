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
end)

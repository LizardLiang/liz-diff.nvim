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

  -- M.split_meta() backs M.open()'s cache-restore routing (Hermes M1): it
  -- decides which of state.current_pr / state.current_range a cached session
  -- meta object belongs in, keyed off `.kind`.
  describe('split_meta()', function()
    local liz_diff

    before_each(function()
      liz_diff = require('tests.helpers').reset_module('liz_diff')
    end)

    it('routes a kind="pr" meta into the pr slot only', function()
      local meta = { kind = 'pr', n = 5 }
      local pr_out, range_out = liz_diff.split_meta(meta)
      assert.are.equal(meta, pr_out)
      assert.is_nil(range_out)
    end)

    it('routes a kind="range" meta into the range slot only', function()
      local meta = { kind = 'range', base_rev = 'a', head_rev = 'b' }
      local pr_out, range_out = liz_diff.split_meta(meta)
      assert.is_nil(pr_out)
      assert.are.equal(meta, range_out)
    end)

    it('returns (nil, nil) for a nil meta (plain single-ref keyword)', function()
      local pr_out, range_out = liz_diff.split_meta(nil)
      assert.is_nil(pr_out)
      assert.is_nil(range_out)
    end)

    it('returns (nil, nil) for a meta with no recognized kind', function()
      local pr_out, range_out = liz_diff.split_meta({ foo = 'bar' })
      assert.is_nil(pr_out)
      assert.is_nil(range_out)
    end)
  end)

  -- M.open() wiring — drives the real on_submit/on_select callbacks (captured
  -- via a mocked ui.open, exactly like the real UI hands them to keymaps)
  -- with git.diff/git.resolve_range/pr.detect_provider stubbed, so the
  -- run_diff -> state -> open_file_at dispatch wiring is regression-tested
  -- end to end without a live float or real git/network calls. This is the
  -- harness Hermes's mutation run (M1-M4) showed was missing: each mutation
  -- kept the then-171/171 suite green because nothing exercised this wiring,
  -- only its already-pure pieces (resolve_open_mode, parse_range, ...).
  describe('M.open() wiring — run_diff / on_select / next dispatch', function()
    local liz_diff, ui, git, diff, pr, cache
    local orig
    local captured

    before_each(function()
      liz_diff = require('tests.helpers').reset_module('liz_diff')
      ui = require('liz_diff.ui')
      git = require('liz_diff.git')
      diff = require('liz_diff.diff')
      pr = require('liz_diff.pr')
      cache = require('liz_diff.cache')
      cache.clear()

      orig = {
        ui_open = ui.open,
        ui_close = ui.close,
        ui_is_open = ui.is_open,
        ui_focus = ui.focus,
        ui_set_prompt_text = ui.set_prompt_text,
        ui_set_results = ui.set_results,
        ui_set_error = ui.set_error,
        ui_set_empty = ui.set_empty,
        ui_get_cursor_index = ui.get_cursor_index,
        ui_set_files_ref = ui._set_files_ref,
        ui_format_line = ui.format_line,
        git_is_git_repo = git.is_git_repo,
        git_repo_root = git.repo_root,
        git_diff = git.diff,
        git_resolve_range = git.resolve_range,
        pr_detect_provider = pr.detect_provider,
        diff_open = diff.open,
        diff_open_pr = diff.open_pr,
        diff_open_commits = diff.open_commits,
      }

      captured = { cursor_index = 1 }
      -- Mirrors real ui.open's contract: hand init.lua its three callbacks so
      -- tests can invoke them directly, exactly as the real keymaps would.
      ui.open = function(on_submit, on_select, on_refresh)
        captured.on_submit = on_submit
        captured.on_select = on_select
        captured.on_refresh = on_refresh
      end
      ui.close = function() end
      ui.is_open = function() return false end
      ui.focus = function() end
      ui.set_prompt_text = function() end
      ui.set_results = function() end
      ui.set_error = function(msg) captured.error = msg end
      ui.set_empty = function() end
      ui.get_cursor_index = function() return captured.cursor_index end
      -- Normally assigned inside the real ui.open(); our mock above replaces
      -- ui.open wholesale, so init.lua's ui._set_files_ref(files) call needs
      -- a no-op here or it errors calling a nil value.
      ui._set_files_ref = function() end
      -- format_files() (init.lua) calls the real ui.format_line() on every
      -- fetched file regardless of whether ui.set_results is mocked; the
      -- fake file fixtures below only carry status/filepath, so the real
      -- formatter (which needs numeric insertions/deletions) would error.
      ui.format_line = function() return '' end

      git.is_git_repo = function() return true end
      git.repo_root = function() return '/fake/repo' end
    end)

    after_each(function()
      ui.open = orig.ui_open
      ui.close = orig.ui_close
      ui.is_open = orig.ui_is_open
      ui.focus = orig.ui_focus
      ui.set_prompt_text = orig.ui_set_prompt_text
      ui.set_results = orig.ui_set_results
      ui.set_error = orig.ui_set_error
      ui.set_empty = orig.ui_set_empty
      ui.get_cursor_index = orig.ui_get_cursor_index
      ui.format_line = orig.ui_format_line
      ui._set_files_ref = orig.ui_set_files_ref
      git.is_git_repo = orig.git_is_git_repo
      git.repo_root = orig.git_repo_root
      git.diff = orig.git_diff
      git.resolve_range = orig.git_resolve_range
      pr.detect_provider = orig.pr_detect_provider
      diff.open = orig.diff_open
      diff.open_pr = orig.diff_open_pr
      diff.open_commits = orig.diff_open_commits
      cache.clear()
    end)

    -- Hermes M2 (removed `state.current_range = resolved` in run_diff) / M3
    -- (removed the 'range' branch in open_file_at): either mutation alone
    -- means a resolved range keyword no longer reaches diff.open_commits.
    it('a resolved range keyword dispatches to diff.open_commits on select, not open/open_pr', function()
      git.diff = function(_, _, callback)
        callback(nil, { { status = 'M', filepath = 'f.lua' } })
        return {}
      end
      git.resolve_range = function() return { base_rev = 'X', head_rev = 'Y' } end

      local commits_spec
      diff.open_commits = function(spec) commits_spec = spec end
      diff.open_pr = function() error('should not call open_pr for a range keyword') end
      diff.open = function() error('should not call open for a range keyword') end

      liz_diff.open()
      captured.on_submit('a...b')
      captured.on_select({ status = 'M', filepath = 'f.lua' })

      assert.is_not_nil(commits_spec)
      assert.are.equal('X', commits_spec.base_rev)
      assert.are.equal('Y', commits_spec.head_rev)
    end)

    -- Hermes M1: reopening the float (cache-restore branch) must route a
    -- cached RANGE meta into current_range, never current_pr. A mutation
    -- reverting to `state.current_pr = cached.meta` puts the range object
    -- straight into current_pr, which resolve_open_mode misreads as 'pr'.
    it('reopening from cache restores a cached range session into current_range, not current_pr', function()
      git.diff = function(_, _, callback)
        callback(nil, { { status = 'M', filepath = 'f.lua' } })
        return {}
      end
      git.resolve_range = function() return { base_rev = 'X', head_rev = 'Y' } end

      liz_diff.open()
      captured.on_submit('a...b')

      -- Simulate closing and reopening the float: a second M.open() call
      -- hits the cache-restore branch since state.current_keyword persists.
      liz_diff.open()

      local commits_calls, pr_calls = 0, 0
      diff.open_commits = function() commits_calls = commits_calls + 1 end
      diff.open_pr = function() pr_calls = pr_calls + 1 end
      diff.open = function() error('should not call open for a restored range session') end

      captured.on_select({ status = 'M', filepath = 'f.lua' })

      assert.are.equal(1, commits_calls)
      assert.are.equal(0, pr_calls)
    end)

    -- Hermes M4: switching from a resolved range keyword to a PR keyword
    -- must clear current_range. Forcing pr.detect_provider to fail lets the
    -- PR branch short-circuit right after its two clear-lines, isolating
    -- exactly the assignment M4 removes (no CLI/network mocking needed).
    it('switching from a resolved range to a PR keyword clears current_range', function()
      git.diff = function(_, _, callback)
        callback(nil, { { status = 'M', filepath = 'f.lua' } })
        return {}
      end
      git.resolve_range = function() return { base_rev = 'X', head_rev = 'Y' } end
      pr.detect_provider = function() return nil end

      liz_diff.open()
      captured.on_submit('a...b') -- primes current_range = { base_rev = 'X', head_rev = 'Y' }
      captured.on_submit('#12') -- pr branch: clears current_pr/current_range, then errors on provider detection

      assert.are.equal('liz-diff: could not detect GitHub/GitLab from the origin remote', captured.error)

      local commits_calls = 0
      diff.open_commits = function() commits_calls = commits_calls + 1 end
      diff.open_pr = function() end
      diff.open = function() end

      captured.on_select({ status = 'M', filepath = 'f.lua' })

      assert.are.equal(0, commits_calls)
    end)

    -- Hermes SUGGESTION 1: ]f/[f must keep using the keyword/mode/root the
    -- user actually selected from, even if a LATER submit (never selected
    -- from) changed the live current_* fields to a different keyword's.
    it('a later submit without selecting does not corrupt an already-armed nav session', function()
      git.diff = function(reference, _, callback)
        if reference == 'main' then
          callback(nil, { { status = 'M', filepath = 'main.lua' } })
        else
          callback(nil, { { status = 'M', filepath = 'range.lua' } })
        end
        return {}
      end
      git.resolve_range = function() return { base_rev = 'a', head_rev = 'b' } end

      local open_calls = {}
      diff.open = function(reference, file) open_calls[#open_calls + 1] = { reference = reference, file = file } end
      diff.open_commits = function() error('should not reach open_commits for the frozen main-list nav session') end

      liz_diff.open()
      captured.on_submit('main')
      captured.on_select({ status = 'M', filepath = 'main.lua' }) -- arms the nav session for 'main'

      open_calls = {} -- isolate the effect of the later submit + ]f below
      captured.on_submit('a...b') -- switches live fetch state; never selected from

      liz_diff.next() -- ]f

      assert.are.equal(1, #open_calls)
      assert.are.equal('main', open_calls[1].reference)
      assert.are.equal('main.lua', open_calls[1].file.filepath)
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

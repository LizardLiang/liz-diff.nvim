require('tests.helpers')

describe('liz-diff.diff', function()
  -- diff.lua is heavily Neovim-API dependent (nvim_open_win, diffthis, vsplit).
  -- These are contract tests — they define the expected behavior for integration testing.

  local diff

  before_each(function()
    package.loaded['liz_diff.diff'] = nil
    diff = require('liz_diff.diff')
  end)

  describe('ref_buffer_name()', function()
    it('builds liz-diff://<label>/<path> with no suffix by default', function()
      assert.are.equal('liz-diff://HEAD/a.lua', diff.ref_buffer_name('HEAD', 'a.lua'))
    end)

    it('appends " (new file)" when is_new_file is true', function()
      assert.are.equal('liz-diff://HEAD/new.lua (new file)', diff.ref_buffer_name('HEAD', 'new.lua', true))
    end)

    it('does not append the suffix when is_new_file is false', function()
      assert.are.equal('liz-diff://main/a.lua', diff.ref_buffer_name('main', 'a.lua', false))
    end)
  end)

  describe('ref_rev() / ref_label() — empty-reference baseline is HEAD', function()
    it('ref_rev("") targets HEAD (not the bare index)', function()
      assert.are.equal('HEAD:', diff.ref_rev(''))
    end)

    it('ref_rev(ref) targets the given reference', function()
      assert.are.equal('main:', diff.ref_rev('main'))
    end)

    it('ref_label("") is HEAD (not INDEX)', function()
      assert.are.equal('HEAD', diff.ref_label(''))
    end)

    it('ref_label(ref) is the given reference', function()
      assert.are.equal('main', diff.ref_label('main'))
    end)
  end)

  -- resolve_ref_content() backs M.open()'s "always attempt git show, never a
  -- silent unexplained blank pane" contract (tactical plan step 3 / spec-delta
  -- "Reference Pane Fallback In List Flow"). Mocked vim.fn.system + a
  -- monkey-patched git.is_new_file keep this a pure-logic unit test, no real
  -- Neovim splits required.
  describe('resolve_ref_content()', function()
    local git
    local orig_is_new_file

    before_each(function()
      git = require('liz_diff.git')
      orig_is_new_file = git.is_new_file
    end)

    after_each(function()
      git.is_new_file = orig_is_new_file
    end)

    it('returns the content on a successful git show', function()
      vim.fn.system = function() return 'file contents\n' end
      vim.v = { shell_error = 0 }
      local content, is_new, warning = diff.resolve_ref_content('/repo', 'HEAD:', 'HEAD', 'a.lua')
      assert.are.equal('file contents\n', content)
      assert.is_false(is_new)
      assert.is_nil(warning)
    end)

    it('returns is_new=true with no warning when the path is absent at the ref', function()
      vim.fn.system = function() return "fatal: path 'new.lua' does not exist in 'HEAD'\n" end
      vim.v = { shell_error = 128 }
      git.is_new_file = function() return true end
      local content, is_new, warning = diff.resolve_ref_content('/repo', 'HEAD:', 'HEAD', 'new.lua')
      assert.are.equal('', content)
      assert.is_true(is_new)
      assert.is_nil(warning)
    end)

    it('returns a warning naming the file for an unexpected (non-new-file) failure', function()
      vim.fn.system = function() return 'fatal: unable to read tree object\n' end
      vim.v = { shell_error = 128 }
      git.is_new_file = function() return false end
      local content, is_new, warning = diff.resolve_ref_content('/repo', 'HEAD:', 'HEAD', 'broken.lua')
      assert.are.equal('', content)
      assert.is_false(is_new)
      assert.is_not_nil(warning)
      assert.is_not_nil(warning:find('broken.lua', 1, true))
      assert.is_not_nil(warning:find('unable to read tree object', 1, true))
    end)
  end)

  -- M.pane_path() backs :LizDiffPaths' on-disk-vs-virtual display rule
  -- (tactical plan liz-diff-show-paths / spec-delta path-overlay.md PO-3/PO-4).
  -- Runs against real (throwaway) Neovim buffers rather than mocks, since the
  -- function itself is a handful of real vim.b / nvim_buf_get_name /
  -- vim.bo reads.
  describe('pane_path()', function()
    local bufs = {}

    after_each(function()
      for _, buf in ipairs(bufs) do
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
      bufs = {}
    end)

    it('prefers the stashed vim.b[buf].liz_diff_path over the buffer name', function()
      local buf = vim.api.nvim_create_buf(false, true)
      bufs[#bufs + 1] = buf
      vim.api.nvim_buf_set_name(buf, 'liz-diff://HEAD/a.lua')
      vim.b[buf].liz_diff_path = 'HEAD:/repo/a.lua'
      assert.are.equal('HEAD:/repo/a.lua', diff.pane_path(buf))
    end)

    it('returns the full absolute path for a real on-disk buffer (empty buftype, no stash)', function()
      local buf = vim.api.nvim_create_buf(false, false)
      bufs[#bufs + 1] = buf
      vim.api.nvim_buf_set_name(buf, 'pane_path_real.lua')
      local expected = vim.fn.fnamemodify('pane_path_real.lua', ':p')
      assert.are.equal(expected, diff.pane_path(buf))
    end)

    it('falls back to the raw buffer name for a virtual (non-empty buftype) buffer with no stash', function()
      local buf = vim.api.nvim_create_buf(false, true)
      bufs[#bufs + 1] = buf
      vim.api.nvim_buf_set_name(buf, 'liz-diff://HEAD/b.lua')
      assert.are.equal('liz-diff://HEAD/b.lua', diff.pane_path(buf))
    end)
  end)

  -- M.show_paths()'s no-active-diff branch (PO-6): INFO notify, no extmark.
  -- The "overlay renders / blinks / clears" branch needs real diff windows
  -- and is left as an integration pending case below, matching this file's
  -- existing convention for window-dependent behavior.
  describe('show_paths() — no active diff', function()
    local orig

    before_each(function()
      orig = {
        list_wins = vim.api.nvim_tabpage_list_wins,
        win_is_valid = vim.api.nvim_win_is_valid,
        get_option_value = vim.api.nvim_get_option_value,
        notify = vim.notify,
        set_extmark = vim.api.nvim_buf_set_extmark,
      }
    end)

    after_each(function()
      vim.api.nvim_tabpage_list_wins = orig.list_wins
      vim.api.nvim_win_is_valid = orig.win_is_valid
      vim.api.nvim_get_option_value = orig.get_option_value
      vim.notify = orig.notify
      vim.api.nvim_buf_set_extmark = orig.set_extmark
    end)

    it('notifies INFO "no active diff" and places no extmark when no window has diff set', function()
      vim.api.nvim_tabpage_list_wins = function() return { 1000, 1001 } end
      vim.api.nvim_win_is_valid = function() return true end
      vim.api.nvim_get_option_value = function(name, opts)
        if name == 'diff' then
          return false
        end
        return orig.get_option_value(name, opts)
      end

      local notified = {}
      vim.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end

      local extmark_called = false
      vim.api.nvim_buf_set_extmark = function(...)
        extmark_called = true
      end

      diff.show_paths()

      assert.are.equal(1, #notified)
      assert.are.equal('liz-diff: no active diff', notified[1].msg)
      assert.are.equal(vim.log.levels.INFO, notified[1].level)
      assert.is_false(extmark_called)
    end)
  end)

  -- Race guard (PO-5): a second show_paths() within PATHS_BLINK_MS must not
  -- have its overlay wiped early by the first call's stale deferred clear.
  -- vim.defer_fn is stubbed to capture callbacks instead of scheduling a
  -- real timer, so both the stale and the fresh callback can be invoked
  -- deterministically and their effects asserted directly.
  describe('show_paths() — overlapping invocations (race guard)', function()
    local orig

    before_each(function()
      orig = {
        list_wins = vim.api.nvim_tabpage_list_wins,
        win_is_valid = vim.api.nvim_win_is_valid,
        get_option_value = vim.api.nvim_get_option_value,
        win_get_buf = vim.api.nvim_win_get_buf,
        set_extmark = vim.api.nvim_buf_set_extmark,
        clear_namespace = vim.api.nvim_buf_clear_namespace,
        defer_fn = vim.defer_fn,
      }
    end)

    after_each(function()
      vim.api.nvim_tabpage_list_wins = orig.list_wins
      vim.api.nvim_win_is_valid = orig.win_is_valid
      vim.api.nvim_get_option_value = orig.get_option_value
      vim.api.nvim_win_get_buf = orig.win_get_buf
      vim.api.nvim_buf_set_extmark = orig.set_extmark
      vim.api.nvim_buf_clear_namespace = orig.clear_namespace
      vim.defer_fn = orig.defer_fn
    end)

    it('a stale deferred clear from an earlier call is a no-op once a newer call has run', function()
      local buf = vim.api.nvim_create_buf(false, true)

      vim.api.nvim_tabpage_list_wins = function() return { 2000 } end
      vim.api.nvim_win_is_valid = function() return true end
      vim.api.nvim_get_option_value = function(name, opts)
        if name == 'diff' then
          return true
        end
        return orig.get_option_value(name, opts)
      end
      vim.api.nvim_win_get_buf = function() return buf end
      vim.api.nvim_buf_set_extmark = function() end

      local clears = 0
      vim.api.nvim_buf_clear_namespace = function(...)
        clears = clears + 1
      end

      local deferred = {}
      vim.defer_fn = function(fn, ms)
        deferred[#deferred + 1] = fn
      end

      diff.show_paths()
      diff.show_paths()

      assert.are.equal(2, #deferred)

      clears = 0
      deferred[1]() -- stale callback from the first (superseded) call
      assert.are.equal(0, clears)

      deferred[2]() -- fresh callback from the second (current) call
      assert.are.equal(1, clears)
    end)
  end)

  pending('open() with Modified file opens vimdiff with working left, ref right')
  pending('open() with Added file opens vimdiff with empty (new file) ref pane on the right')
  pending('open() with Deleted file opens vimdiff with a [deleted] placeholder on the left')
  pending('open() with Renamed file uses old_path for reference content')
  pending('open() with binary file shows notify and returns without opening diff')
  pending('open() with empty reference uses HEAD as old side, and (new file) suffix for status A')
  pending('reference buffer has buftype=nofile and bufhidden=wipe')
  pending('reference buffer name follows liz-diff://<ref>/<path> convention')
  pending('reference buffer filetype matches source file extension')
  pending('cleanup_previous() wipes tracked reference buffers no longer in a window')

  pending('open_current() diffs working file on LEFT, HEAD content on RIGHT')
  pending('open_current() reflects the live (unsaved) buffer on the left')
  pending('open_current() with file absent at ref opens an empty right pane')
  pending('open_current() new-file reference buffer name carries the "(new file)" marker')
  pending('open_current() no-ops with notify when buffer has no file / not a repo')
  pending('open_current() reuses cleanup_previous() before opening')
end)
